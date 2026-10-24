#!/usr/bin/env bash
# Provisiona o armazenamento dos arquivos do candidato no MinIO de HML
# (ADR-0146 do uniplus-api, uniplus-infra#682):
#
#   - cria a chave mestra `uniplus-arquivos-candidato` no KES (identidade
#     `provisioner`, a única que cria) e liga o MinIO ao KES por mTLS (identidade
#     `minio`, só generate/decrypt);
#   - cria os buckets de envio (quarentena) e definitivo, ambos privados, com
#     SSE-KMS como cifra padrão;
#   - expiração de 1 dia no bucket de envio, OBRIGATÓRIA: se a regra não puder ser
#     criada ou conferida, o script falha (sem `|| true`);
#   - CORS do MinIO para a origem do web de HML, expondo o ETag;
#   - políticas e usuários da API e do verificador, conforme a tabela da ADR;
#   - audit webhook, quando AUDIT_WEBHOOK_ENDPOINT é informado.
#
# Ordem: (1) provision-verificacao-prerequisites.sh; (2) o ArgoCD sincroniza o KES
# (Application platform-kes-in-cluster saudável); (3) este script, na VM de HML.
# Idempotente. Reinicia o MinIO só quando a configuração do KES/CORS/audit muda.
#
# Variáveis:
#   HOST_IP                 IP do host (default 192.168.21.134)
#   DATA_BASE               default /var/lib/uniplus
#   ORIGEM_WEB              origem do web para o CORS (default https://uniplus-hml.unifesspa.edu.br)
#   AUDIT_WEBHOOK_ENDPOINT  URL do coletor de logs que recebe o audit do MinIO.
#                           Vazio = audit NÃO configurado (o script avisa no fim).
#   AUDIT_WEBHOOK_TOKEN     token de autenticação do coletor (opcional)
set -euo pipefail

HOST_IP="${HOST_IP:-192.168.21.134}"
DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
ORIGEM_WEB="${ORIGEM_WEB:-https://uniplus-hml.unifesspa.edu.br}"
AUDIT_WEBHOOK_ENDPOINT="${AUDIT_WEBHOOK_ENDPOINT:-}"
AUDIT_WEBHOOK_TOKEN="${AUDIT_WEBHOOK_TOKEN:-}"

KES_IMAGE="${KES_IMAGE:-quay.io/minio/kes:2025-03-12T09-35-18Z}"
MC_IMAGE="quay.io/minio/mc:latest"
KES_PORT=7373
KEY_NAME="uniplus-arquivos-candidato"
BUCKET_ENVIO="uniplus-candidato-envio"
BUCKET_DEFINITIVO="uniplus-candidato-definitivo"
KES_ENV_FILE="/etc/uniplus-minio-kes.env"
KES_DIR="/etc/uniplus-minio-kes"
APPLIED_MARKER="$DATA_BASE/minio/.kes-applied.sha256"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY_DIR="$SCRIPT_DIR/minio"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
falha() { echo "ERRO: $*" >&2; exit 1; }

tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
cleanup() {
    vault_desconectar 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# shellcheck source=lib-vault.sh
source "$SCRIPT_DIR/lib-vault.sh"
command -v docker >/dev/null || falha "docker ausente"
for politica in arquivos-candidato-api arquivos-candidato-verificador; do
    [[ -f "$POLICY_DIR/$politica.policy.json" ]] || falha "política ausente: $POLICY_DIR/$politica.policy.json"
done
vault_conectar "$tmpdir"

# --- Segredos do Vault (só em memória/tmpdir 0700) ----------------------------
kes_cert=$(vault_get standalone/kes/server cert) || falha "certificado do KES ausente no Vault (rodar provision-verificacao-prerequisites.sh)"
kes_key_minio=$(vault_get standalone/kes/api-keys minio) || falha "chave de API do MinIO no KES ausente no Vault"
kes_key_provisioner=$(vault_get standalone/kes/api-keys provisioner) || falha "chave de API do provisioner no KES ausente no Vault"
api_access=$(vault_get standalone/minio/arquivos-candidato-api access_key) || falha "credencial da API ausente no Vault"
api_secret=$(vault_get standalone/minio/arquivos-candidato-api secret_key) || falha "credencial da API ausente no Vault"
ver_access=$(vault_get standalone/minio/arquivos-candidato-verificador access_key) || falha "credencial do verificador ausente no Vault"
ver_secret=$(vault_get standalone/minio/arquivos-candidato-verificador secret_key) || falha "credencial do verificador ausente no Vault"
printf '%s\n' "$kes_cert" >"$tmpdir/kes.crt"

# --- KES no ar ----------------------------------------------------------------
log "Aguardando o KES em https://$HOST_IP:$KES_PORT"
tentativa=0
until curl -fsS --max-time 5 --cacert "$tmpdir/kes.crt" "https://$HOST_IP:$KES_PORT/v1/ready" >/dev/null 2>&1; do
    tentativa=$((tentativa + 1))
    [[ "$tentativa" -lt 60 ]] || falha "KES não respondeu em 5 min (Application platform-kes-in-cluster sincronizada? NetworkPolicy do hostPort?)"
    sleep 5
done

# --- Chave mestra -------------------------------------------------------------
# A identidade provisioner é a única autorizada a criar. "Já existe" é o estado
# desejado; qualquer outro erro derruba o script.
log "Criando a chave $KEY_NAME no KES (se ainda não existir)"
kes_cli_env="$tmpdir/kes-cli.env"
{
    echo "KES_API_KEY=$kes_key_provisioner"
    echo "KES_SERVER=https://$HOST_IP:$KES_PORT"
    echo "SSL_CERT_FILE=/ca/kes.crt"
} >"$kes_cli_env"
chmod 600 "$kes_cli_env"
if saida=$(sudo docker run --rm --network host --env-file "$kes_cli_env" \
    -v "$tmpdir/kes.crt:/ca/kes.crt:ro" "$KES_IMAGE" key create "$KEY_NAME" 2>&1); then
    log "Chave criada."
elif grep -qi 'exist' <<<"$saida"; then
    log "Chave já existia."
else
    falha "não consegui criar a chave no KES: $saida"
fi
rm -f "$kes_cli_env"
unset kes_key_provisioner

# --- Configuração do MinIO (KES, CORS, audit) ---------------------------------
sudo install -d -m 755 "$KES_DIR"
sudo install -m 644 "$tmpdir/kes.crt" "$KES_DIR/kes.crt"
{
    echo "MINIO_KMS_KES_ENDPOINT=https://$HOST_IP:$KES_PORT"
    echo "MINIO_KMS_KES_API_KEY=$kes_key_minio"
    echo "MINIO_KMS_KES_KEY_NAME=$KEY_NAME"
    echo "MINIO_KMS_KES_CAPATH=/etc/minio/extra/kes.crt"
    # O MinIO não tem CORS por bucket: a origem permitida é global. O ETag já faz
    # parte dos cabeçalhos expostos por padrão (conferido mais adiante).
    echo "MINIO_API_CORS_ALLOW_ORIGIN=$ORIGEM_WEB"
    if [[ -n "$AUDIT_WEBHOOK_ENDPOINT" ]]; then
        echo "MINIO_AUDIT_WEBHOOK_ENABLE_COLETOR=on"
        echo "MINIO_AUDIT_WEBHOOK_ENDPOINT_COLETOR=$AUDIT_WEBHOOK_ENDPOINT"
        [[ -z "$AUDIT_WEBHOOK_TOKEN" ]] || echo "MINIO_AUDIT_WEBHOOK_AUTH_TOKEN_COLETOR=$AUDIT_WEBHOOK_TOKEN"
    fi
} >"$tmpdir/minio-kes.env"
sudo install -m 600 -o root -g root "$tmpdir/minio-kes.env" "$KES_ENV_FILE"
unset kes_key_minio

# O wrapper de HML reescreve a unit entregando o ambiente acima ao container.
DATA_HOST_IP="$HOST_IP" "$SCRIPT_DIR/setup-minio.sh" --skip-buckets
estado=$(sudo sha256sum "$KES_ENV_FILE" "$KES_DIR/kes.crt" /etc/systemd/system/uniplus-minio.service | awk '{print $1}' | sha256sum | awk '{print $1}')
if [[ "$(sudo cat "$APPLIED_MARKER" 2>/dev/null || true)" != "$estado" ]]; then
    log "Configuração do KES/CORS/audit mudou — reiniciando o MinIO"
    sudo systemctl restart uniplus-minio
    tentativa=0
    until curl -sf "http://$HOST_IP:9000/minio/health/live" >/dev/null 2>&1; do
        tentativa=$((tentativa + 1))
        [[ "$tentativa" -lt 18 ]] || falha "MinIO não voltou em 90 s (journalctl -u uniplus-minio)"
        sleep 5
    done
    printf '%s\n' "$estado" | sudo tee "$APPLIED_MARKER" >/dev/null
else
    log "Configuração do MinIO inalterada — sem reinício."
fi

# --- mc ----------------------------------------------------------------------
# Credenciais por --env-file em tmpdir 0700, nunca em argv (visível em `ps`).
root_user=$(sudo grep '^root_user=' "$DATA_BASE/minio/.bootstrap-creds" | cut -d= -f2-)
root_pw=$(sudo grep '^root_pw=' "$DATA_BASE/minio/.bootstrap-creds" | cut -d= -f2-)
[[ -n "$root_user" && -n "$root_pw" ]] || falha "credenciais root do MinIO ausentes em $DATA_BASE/minio/.bootstrap-creds"
mc_env="$tmpdir/mc.env"
{
    echo "MC_HOST_uniplus=http://${root_user}:${root_pw}@${HOST_IP}:9000"
    echo "API_ACCESS=$api_access"
    echo "API_SECRET=$api_secret"
    echo "VER_ACCESS=$ver_access"
    echo "VER_SECRET=$ver_secret"
} >"$mc_env"
chmod 600 "$mc_env"
unset root_user root_pw api_secret ver_secret

mc() {
    sudo docker run --rm --network host --env-file "$mc_env" -v "$POLICY_DIR:/politicas:ro" "$MC_IMAGE" "$@"
}
mc_sh() {
    sudo docker run --rm --network host --env-file "$mc_env" -v "$POLICY_DIR:/politicas:ro" \
        --entrypoint /bin/sh "$MC_IMAGE" -c "$1"
}

# --- O MinIO consegue usar a chave? (generate + decrypt) ----------------------
log "Conferindo a chave no KES pelo MinIO"
mc admin kms key status uniplus "$KEY_NAME" || falha "o MinIO não consegue gerar/decifrar com a chave $KEY_NAME"

# --- Buckets e cifra padrão ---------------------------------------------------
for bucket in "$BUCKET_ENVIO" "$BUCKET_DEFINITIVO"; do
    log "Bucket $bucket (privado, SSE-KMS padrão)"
    mc mb --ignore-existing "uniplus/$bucket"
    mc encrypt set sse-kms "$KEY_NAME" "uniplus/$bucket"
    mc encrypt info "uniplus/$bucket" | grep -q "$KEY_NAME" || falha "$bucket sem a cifra padrão $KEY_NAME"
    # Bucket recém-criado já é privado; falha se alguém abriu política anônima.
    if mc anonymous get "uniplus/$bucket" | grep -qiE 'public|download|upload'; then
        falha "$bucket tem política anônima"
    fi
done

# --- Expiração do bucket de envio (obrigatória) --------------------------------
verificar_expiracao() {
    mc ilm rule export "uniplus/$BUCKET_ENVIO" | python3 -c '
import json, sys
regras = json.load(sys.stdin).get("Rules", [])
ok = [r for r in regras if r.get("Status") == "Enabled" and r.get("Expiration", {}).get("Days") == 1]
sys.exit(0 if ok else 1)'
}
if verificar_expiracao; then
    log "Expiração de 1 dia já presente em $BUCKET_ENVIO"
else
    log "Criando a regra de expiração de 1 dia em $BUCKET_ENVIO"
    mc ilm rule add --expire-days 1 "uniplus/$BUCKET_ENVIO"
fi
verificar_expiracao || falha "$BUCKET_ENVIO sem a regra de expiração de 1 dia — o provisionamento não pode continuar"

# --- Políticas e usuários -----------------------------------------------------
mc admin policy create uniplus arquivos-candidato-api /politicas/arquivos-candidato-api.policy.json
mc admin policy create uniplus arquivos-candidato-verificador /politicas/arquivos-candidato-verificador.policy.json
# `user add` é idempotente (reaplica a senha do Vault); o attach só quando falta.
mc_sh 'mc admin user add uniplus "$API_ACCESS" "$API_SECRET" && mc admin user add uniplus "$VER_ACCESS" "$VER_SECRET"'
mc_sh '
set -e
anexar() {
    if ! mc admin user info uniplus "$1" --json | grep -q "\"policyName\":\"[^\"]*$2"; then
        mc admin policy attach uniplus "$2" --user "$1"
    fi
    mc admin user info uniplus "$1" --json | grep -q "\"policyName\":\"$2\"" \
        || { echo "usuário $1 deveria ter só a política $2" >&2; exit 1; }
}
anexar "$API_ACCESS" arquivos-candidato-api
anexar "$VER_ACCESS" arquivos-candidato-verificador
'
log "Usuários do MinIO (conferir: ninguém além dos serviços e do root):"
mc admin user list uniplus

# --- CORS: origem do web e ETag exposto ---------------------------------------
log "Conferindo o CORS do bucket de envio"
cabecalhos=$(curl -sS -D - -o /dev/null -H "Origin: $ORIGEM_WEB" "http://$HOST_IP:9000/$BUCKET_ENVIO/_cors")
grep -qi "^access-control-allow-origin: $ORIGEM_WEB" <<<"$cabecalhos" || falha "CORS não libera $ORIGEM_WEB"
grep -qi '^access-control-expose-headers:.*etag' <<<"$cabecalhos" || falha "CORS não expõe o ETag"

# --- Audit --------------------------------------------------------------------
if [[ -n "$AUDIT_WEBHOOK_ENDPOINT" ]]; then
    log "Audit webhook do MinIO apontado para o coletor informado."
else
    echo "[LACUNA] AUDIT_WEBHOOK_ENDPOINT não informado: o audit do MinIO NÃO está sendo enviado a coletor algum." >&2
    echo "         Em HML o Loki e o OTel Collector estão desligados; informe o endpoint quando houver coletor e rode de novo." >&2
fi

shred -u "$mc_env" 2>/dev/null || rm -f "$mc_env"
log "Armazenamento dos arquivos do candidato provisionado: $BUCKET_ENVIO e $BUCKET_DEFINITIVO."
