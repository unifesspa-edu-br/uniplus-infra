#!/usr/bin/env bash
# Provisiona o que o Loki, o Tempo e o Grafana precisam fora do cluster:
#
#   - usuários `loki-svc` e `tempo-svc` no MinIO, cada um com a política
#     (loki-rw, tempo-rw; scripts/servicos-no-host/minio/) restrita ao próprio
#     bucket (loki-chunks, tempo-traces), que também são criados se faltarem;
#   - no Vault, plataforma/minio/loki e plataforma/minio/tempo, com accesskey,
#     secretkey, endpoint (FQDN:9000, sem esquema) e region, que os
#     ExternalSecrets dos charts leem;
#   - no Vault, plataforma/grafana/admin (username e password), lido pelo
#     ExternalSecret do Grafana.
#
# Idempotente: credencial que já existe no Vault é preservada, nunca regerada,
# e o usuário do MinIO é reaplicado a partir dela. Nenhum segredo vai a argv,
# a log ou a arquivo fora de um diretório temporário 0700.
#
# Rodar na VM de dados, com o Vault aberto, antes de ligar os charts de
# observabilidade (docs/RUNBOOKS.md, seção de observabilidade).
#
# Uso: [AMBIENTE=hml INFRA_FQDN=<nome da VM de dados>] ./provisionar-observabilidade.sh [--dry-run]
#
# Variáveis (as de lib-comum.sh valem aqui; fora de produção, INFRA_FQDN é
# obrigatório):
#   VAULT_URL   Endereço HTTPS do Vault (ver lib-vault.sh).
#   MC_IMAGE    Imagem do cliente do MinIO.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc:latest}"
POLICY_DIR="$SCRIPT_DIR/minio"
REGIAO_S3="us-east-1"
# Componente, usuário, política e bucket.
SERVICOS=("loki loki-svc loki-rw loki-chunks" "tempo tempo-svc tempo-rw tempo-traces")

analisar_argumentos "$@"
exigir_usuario_comum
exigir_infra_fqdn
if $DRY_RUN; then
    echo "[DRY-RUN] criaria, se ausentes, os buckets loki-chunks e tempo-traces em $INFRA_FQDN:9000"
    echo "[DRY-RUN] gravaria no Vault, se ausentes: plataforma/minio/loki, plataforma/minio/tempo e plataforma/grafana/admin"
    echo "[DRY-RUN] aplicaria no MinIO os usuários loki-svc e tempo-svc com as políticas loki-rw e tempo-rw"
    exit 0
fi

for servico in "${SERVICOS[@]}"; do
    read -r _ _ politica _ <<<"$servico"
    [[ -f "$POLICY_DIR/$politica.policy.json" ]] || {
        log_error "Política ausente: $POLICY_DIR/$politica.policy.json"
        exit 1
    }
done
command -v docker >/dev/null || { log_error "docker ausente."; exit 1; }

# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

# Grava a credencial do usuário no Vault só se ainda não existe.
garantir_credencial_minio() {
    local caminho="$1" usuario="$2"
    if vault_existe "$caminho"; then
        log_success "$caminho já existe no Vault; preservado."
        return 0
    fi
    vault_put "$caminho" "accesskey=$usuario" "secretkey=$(openssl rand -hex 24)" \
        "endpoint=$INFRA_FQDN:9000" "region=$REGIAO_S3"
    log_success "$caminho gravado no Vault."
}

garantir_conta_do_grafana() {
    if vault_existe plataforma/grafana/admin; then
        log_success "plataforma/grafana/admin já existe no Vault; preservado."
        return 0
    fi
    vault_put plataforma/grafana/admin "username=admin" "password=$(openssl rand -hex 24)"
    log_success "plataforma/grafana/admin gravado no Vault."
}

# O cliente do MinIO recebe as credenciais por arquivo de ambiente 0600, nunca
# por argv; as de cada usuário se chamam <COMPONENTE>_ACCESS e <COMPONENTE>_SECRET.
preparar_cliente_minio() {
    local env_file="$PROVISIONAR_TMP/mc.env" root_user root_pw servico componente
    root_user=$(ler_credencial "$DATA_BASE/minio/.bootstrap-creds" root_user)
    root_pw=$(ler_credencial "$DATA_BASE/minio/.bootstrap-creds" root_pw)
    [[ -n "$root_user" && -n "$root_pw" ]] || {
        log_error "Credenciais root do MinIO ausentes em $DATA_BASE/minio/.bootstrap-creds."
        exit 1
    }
    {
        echo "MC_HOST_uniplus=https://${root_user}:${root_pw}@${INFRA_FQDN}:9000"
        for servico in "${SERVICOS[@]}"; do
            read -r componente _ _ _ <<<"$servico"
            echo "${componente^^}_ACCESS=$(vault_get "plataforma/minio/$componente" accesskey)"
            echo "${componente^^}_SECRET=$(vault_get "plataforma/minio/$componente" secretkey)"
        done
    } >"$env_file"
    chmod 600 "$env_file"
    MC_ENV_FILE="$env_file"
}

mc() {
    sudo docker run --rm --network host --env-file "$MC_ENV_FILE" \
        -v "$POLICY_DIR:/politicas:ro" "$MC_IMAGE" "$@"
}
mc_sh() {
    sudo docker run --rm --network host --env-file "$MC_ENV_FILE" \
        -v "$POLICY_DIR:/politicas:ro" --entrypoint /bin/sh "$MC_IMAGE" -c "$1"
}

tem_politica() {
    mc admin user info uniplus "$1" --json | grep -q "\"policyName\":\"[^\"]*$2"
}

# Bucket, política e usuário. `user add` é idempotente e reaplica a senha do
# Vault; o attach só ocorre quando falta.
aplicar_no_minio() {
    local componente="$1" politica="$2" bucket="$3" acesso
    acesso=$(vault_get "plataforma/minio/$componente" accesskey)
    mc mb --ignore-existing "uniplus/$bucket"
    mc admin policy create uniplus "$politica" "/politicas/$politica.policy.json"
    mc_sh "mc admin user add uniplus \"\$${componente^^}_ACCESS\" \"\$${componente^^}_SECRET\""
    tem_politica "$acesso" "$politica" || mc admin policy attach uniplus "$politica" --user "$acesso"
    tem_politica "$acesso" "$politica" || {
        log_error "O usuário $acesso deveria ter a política $politica."
        exit 1
    }
    log_success "Usuário $acesso restrito ao bucket $bucket."
}

preparar_provisionamento

for servico in "${SERVICOS[@]}"; do
    read -r componente usuario _ _ <<<"$servico"
    garantir_credencial_minio "plataforma/minio/$componente" "$usuario"
done
garantir_conta_do_grafana

preparar_cliente_minio
for servico in "${SERVICOS[@]}"; do
    read -r componente _ politica bucket <<<"$servico"
    aplicar_no_minio "$componente" "$politica" "$bucket"
done

echo "Observabilidade provisionada. Próximo: ligar prometheus, loki e tempo, otelcol e grafana (docs/RUNBOOKS.md)."
