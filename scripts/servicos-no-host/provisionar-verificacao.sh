#!/usr/bin/env bash
# Provisiona no Vault o que o KES, o RabbitMQ e o MinIO precisam para a
# cifra e a verificação dos arquivos do candidato (ADR-0146 do uniplus-api,
# uniplus-infra#682). É a parte "escrita no Vault" que os charts platform/kes e
# platform/rabbitmq não fazem:
#
#   - política `kes` (só o prefixo `kes-keystore/` do KV de plataforma e a chave
#     `uniplus-kes-kek` do Transit de plataforma, que configurar-vault.sh cria) e
#     role Kubernetes auth `kes` (ServiceAccount kes/kes);
#   - certificado do servidor KES (plataforma/kes/server);
#   - identidades do KES: `minio` (generate/decrypt) e `provisioner` (cria a chave);
#   - senhas do RabbitMQ (admin, API, verificador);
#   - credenciais do MinIO para a API e para o verificador.
#
# Idempotente: o que já existe no Vault é preservado, nunca regerado (regerar uma
# identidade ou uma senha desalinharia quem já a usa). Rodar na VM de infraestrutura,
# com o Vault inicializado e aberto, ANTES de o ArgoCD sincronizar o KES. Em
# seguida, rodar provisionar-arquivos-candidato.sh.
#
# Uso: ./provisionar-verificacao.sh [--dry-run]
#
# Variáveis (as de lib-comum.sh valem aqui):
#   KES_IMAGE   Imagem do KES usada para gerar as identidades.
#   VAULT_URL   Endereço HTTPS do Vault (ver lib-vault.sh).
# O certificado do domínio (TLS_BUNDLE e TLS_KEY) é o certificado do servidor KES.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] provisionaria no Vault a política, a role e as identidades do KES, as senhas do RabbitMQ e as do MinIO"
    exit 0
fi

definir_url_do_vault
HOST_IP="$APP_IP"
KES_CERT_FILE="$TLS_BUNDLE"
KES_KEY_FILE="$TLS_KEY"

KES_IMAGE="${KES_IMAGE:-quay.io/minio/kes:2025-03-12T09-35-18Z}"
KES_NAMESPACE="kes"
KES_SERVICE_ACCOUNT="kes"
TRANSIT_KEY="uniplus-kes-kek"
TRANSIT_MOUNT="plataforma-$AMBIENTE-transit"
# Igual a kes.vault.kvPrefix do chart platform/kes.
KES_KEYSTORE_PREFIX="kes-keystore"
tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
cleanup() {
    vault_desconectar 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# shellcheck source=lib-vault.sh
source "$SCRIPT_DIR/lib-vault.sh"
command -v docker >/dev/null || { echo "Comando obrigatório ausente: docker" >&2; exit 1; }
vault_conectar "$tmpdir"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- Chave que cifra as chaves mestras do KES -------------------------------
# O mount Transit de plataforma e a chave `uniplus-kes-kek` são criados por
# configurar-vault.sh. Aqui só se confere que existem: sem a chave o KES não sobe.
vault_api GET "$TRANSIT_MOUNT/keys/$TRANSIT_KEY"
case "$VAULT_HTTP_STATUS" in
    200) ;;
    404) echo "A chave $TRANSIT_MOUNT/$TRANSIT_KEY não existe; rode configurar-vault.sh antes." >&2; exit 1 ;;
    *) echo "Falha ao consultar a chave Transit (HTTP $VAULT_HTTP_STATUS)." >&2; exit 1 ;;
esac

# --- Política e role do KES --------------------------------------------------
# O KES só toca o prefixo exclusivo do keystore no KV de plataforma (nunca `kes/server`
# nem `kes/api-keys`, que ficam ao lado) e cifra/decifra com a própria chave, no
# Transit de plataforma.
politica=$(python3 -c '
import json, sys
t, kv, p, m = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({"policy": "\n".join([
    "path \"%s/data/%s/*\" { capabilities = [\"create\", \"read\", \"delete\"] }" % (kv, p),
    "path \"%s/metadata/%s/*\" { capabilities = [\"list\", \"delete\"] }" % (kv, p),
    "path \"%s/metadata/%s\" { capabilities = [\"list\"] }" % (kv, p),
    "path \"%s/encrypt/%s\" { capabilities = [\"update\"] }" % (m, t),
    "path \"%s/decrypt/%s\" { capabilities = [\"update\"] }" % (m, t),
]) + "\n"}), end="")' "$TRANSIT_KEY" "plataforma-$AMBIENTE" "$KES_KEYSTORE_PREFIX" "$TRANSIT_MOUNT")
log "Escrevendo a política kes"
vault_api PUT sys/policies/acl/kes "$politica"
[[ "$VAULT_HTTP_STATUS" =~ ^20[04]$ ]] || { echo "Falha ao escrever a política kes (HTTP $VAULT_HTTP_STATUS)." >&2; exit 1; }

log "Escrevendo a role Kubernetes auth kes"
vault_api POST auth/kubernetes/role/kes "$(python3 -c '
import json, sys
print(json.dumps({
    "bound_service_account_names": sys.argv[1],
    "bound_service_account_namespaces": sys.argv[2],
    "policies": "kes",
    "audience": "https://kubernetes.default.svc.cluster.local",
    "ttl": "1h",
}), end="")' "$KES_SERVICE_ACCOUNT" "$KES_NAMESPACE")"
[[ "$VAULT_HTTP_STATUS" =~ ^20[04]$ ]] || {
    echo "Falha ao escrever a role kes (HTTP $VAULT_HTTP_STATUS). O auth kubernetes está habilitado?" >&2
    exit 1
}

# --- Certificado do servidor KES --------------------------------------------
# Autoassinado, quando não há par do domínio, e válido por 1 ano. A SAN inclui o IP
# do host, porque o MinIO chega pelo hostPort. Rotação: apagar
# plataforma/kes/server no Vault e rodar este script e o seguinte de novo.
if vault_existe plataforma/kes/server; then
    log "Certificado do KES já existe no Vault — preservado."
elif [[ -n "$KES_CERT_FILE" ]]; then
    # A chave do domínio é de root (0600): lida com sudo, nunca copiada para fora do Vault.
    sudo test -r "$KES_CERT_FILE" && sudo test -r "$KES_KEY_FILE" || { echo "KES_CERT_FILE e KES_KEY_FILE devem ser legíveis." >&2; exit 1; }
    log "Gravando o certificado do domínio como certificado do servidor KES"
    vault_put plataforma/kes/server "cert=$(sudo cat "$KES_CERT_FILE")" "key=$(sudo cat "$KES_KEY_FILE")"
else
    log "Gerando o certificado do servidor KES"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$tmpdir/kes.key" -out "$tmpdir/kes.crt" -days 365 -subj "/CN=kes" \
        -addext "subjectAltName=DNS:kes,DNS:kes.${KES_NAMESPACE}.svc,DNS:kes.${KES_NAMESPACE}.svc.cluster.local,DNS:localhost,IP:${HOST_IP},IP:127.0.0.1" \
        2>/dev/null
    vault_put plataforma/kes/server "cert=$(cat "$tmpdir/kes.crt")" "key=$(cat "$tmpdir/kes.key")"
    shred -u "$tmpdir/kes.key" 2>/dev/null || rm -f "$tmpdir/kes.key"
fi

# --- Identidades do KES ------------------------------------------------------
# A chave de API é o segredo; a identidade (hash) é o que a política do KES lista.
# As duas chaves ficam em custódia no Vault; só a do MinIO sai de lá, para o host.
tem_identidades=false
tem_chaves=false
vault_existe plataforma/kes/identities && tem_identidades=true
vault_existe plataforma/kes/api-keys && tem_chaves=true
if [[ "$tem_identidades" != "$tem_chaves" ]]; then
    # Regerar as duas desalinharia o que já usa a que sobrou (a política do KES
    # lista a identidade; o MinIO guarda a chave de API). Decisão do operador.
    echo "Estado inconsistente: só um entre plataforma/kes/identities e plataforma/kes/api-keys existe no Vault." >&2
    echo "Restaure o que falta ou apague o que sobrou (e reaplique o KES e o MinIO) antes de rodar de novo." >&2
    exit 1
fi
if [[ "$tem_identidades" == true ]]; then
    log "Identidades do KES já existem no Vault — preservadas."
else
    log "Gerando as identidades minio e provisioner do KES"
    # `identity new` imprime a chave de API e a identidade (SHA-256, 64 hex) juntas.
    # Cada chamada devolve uma chave e a identidade dela.
    nova_identidade() {
        local saida chave identidade
        saida=$(sudo docker run --rm "$KES_IMAGE" identity new)
        chave=$(grep -o -m1 'kes:v1:[A-Za-z0-9+/=]*' <<<"$saida") || return 1
        identidade=$(grep -oE -m1 '\b[0-9a-f]{64}\b' <<<"$saida") || return 1
        printf '%s %s\n' "$chave" "$identidade"
    }
    par_minio=$(nova_identidade) || { echo "Falha ao gerar a identidade do MinIO no KES." >&2; exit 1; }
    par_provisioner=$(nova_identidade) || { echo "Falha ao gerar a identidade de provisionamento no KES." >&2; exit 1; }
    read -r chave_minio id_minio <<<"$par_minio"
    read -r chave_provisioner id_provisioner <<<"$par_provisioner"
    [[ -n "$chave_minio" && -n "$id_minio" && -n "$chave_provisioner" && -n "$id_provisioner" && "$id_minio" != "$id_provisioner" ]] || {
        echo "Falha ao derivar as identidades do KES." >&2
        exit 1
    }
    vault_put plataforma/kes/api-keys "minio=$chave_minio" "provisioner=$chave_provisioner"
    vault_put plataforma/kes/identities "minio=$id_minio" "provisioner=$id_provisioner"
    unset chave_minio chave_provisioner id_minio id_provisioner par_minio par_provisioner
fi

# --- Senhas do RabbitMQ ------------------------------------------------------
# Os nomes de usuário têm de bater com rabbitmq.users no chart platform/rabbitmq.
garantir_senha_rabbitmq() {
    local caminho="$1" usuario="$2"
    if vault_existe "$caminho"; then
        log "Credencial $caminho já existe no Vault — preservada."
    else
        log "Gerando a credencial $caminho"
        vault_put "$caminho" "username=$usuario" "password=$(openssl rand -hex 24)"
    fi
}
garantir_senha_rabbitmq plataforma/rabbitmq/admin rabbitmq-admin
garantir_senha_rabbitmq uniplus/rabbitmq/api uniplus-api
garantir_senha_rabbitmq uniplus/rabbitmq/verificador uniplus-verificador

# --- Credenciais do MinIO para a API e para o verificador ---------------------
# O provisionar-arquivos-candidato.sh cria os usuários no MinIO a partir daqui.
garantir_minio() {
    local caminho="$1" usuario="$2"
    if vault_existe "$caminho"; then
        log "Credencial $caminho já existe no Vault — preservada."
    else
        log "Gerando a credencial $caminho"
        vault_put "$caminho" "access_key=$usuario" "secret_key=$(openssl rand -hex 24)"
    fi
}
garantir_minio uniplus/minio/arquivos-candidato-api uniplus-api-arquivos
garantir_minio uniplus/minio/arquivos-candidato-verificador uniplus-verificador-arquivos

echo "Pré-requisitos da verificação provisionados no Vault. Próximo: sincronizar o KES e o RabbitMQ no ArgoCD e rodar provisionar-arquivos-candidato.sh."
