#!/usr/bin/env bash
# scripts/lab-standalone-single/seed-vault-secrets.sh
#
# Popula no Vault do lab (platform/vault/, Task #409) os secrets que os
# charts uniplus-api-{selecao,portal,ingresso} e keycloak-replica esperam
# nos vaultPaths default (ver apps/uniplus-api-*/values.yaml
# externalSecrets.*.vaultPath). Lê as credenciais das fontes de verdade já
# existentes nesta VM — nunca gera segredo novo — e apenas sincroniza o
# Vault com o que já está vivo:
#   - Redis/MinIO/Kafka: $DATA_BASE/{redis,minio,kafka}/.bootstrap-creds
#     (gerados por setup-{redis,minio,kafka}.sh)
#   - Kafka CA cert: /etc/uniplus-kafka/certs/ca.crt (gerado por setup-kafka.sh)
#   - Keycloak client_secrets M2M: recuperados via kcadm.sh no pod
#     keycloak-replica (mesmo procedimento de docs/RUNBOOKS.md §"Recuperar
#     client_secret"), não lidos de arquivo — o Keycloak é a fonte de verdade.
#
# NÃO cobre secret/standalone/postgres/{selecao,portal,ingresso}: cada role+db
# Postgres dedicado só existe a partir da Task que sobe a respectiva API
# (issue #412/#413/#414) — populado dentro do script/procedimento daquela
# Task, não aqui. Rodar este script de novo depois é seguro (idempotente por
# natureza do `vault kv put`: sempre reflete a fonte de verdade atual).
#
# Uso:
#   ./seed-vault-secrets.sh [--dry-run]
#
# Pré-requisitos: rodar na VM do lab com sudo sem senha (kubeconfig do k3s
# só é legível via sudo — /etc/rancher/k3s/k3s.yaml é root:root 600), Vault
# unsealed e root token disponível em $DATA_BASE/vault/.bootstrap-creds.json
# (Task #409), pod keycloak-replica Running no namespace uniplus.
set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Uso: $0 [--dry-run]"
            exit 0
            ;;
        *) echo "Opção inválida: $arg" >&2; exit 2 ;;
    esac
done

DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
# k3s não expõe kubeconfig legível a usuários comuns (/etc/rancher/k3s/k3s.yaml
# é root:root 600) — mesmo padrão de `sudo` usado no resto do script para
# .bootstrap-creds/vault json.
KUBECTL=(sudo kubectl)
KEYCLOAK_NAMESPACE="${KEYCLOAK_NAMESPACE:-uniplus}"
KEYCLOAK_DEPLOYMENT="${KEYCLOAK_DEPLOYMENT:-keycloak-replica}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-uniplus}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
KAFKA_CA_CERT="${KAFKA_CA_CERT:-/etc/uniplus-kafka/certs/ca.crt}"

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[ OK ] $*"; }
log_warn()    { echo "[WARN] $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }

require_file() {
    if ! sudo test -f "$1" 2>/dev/null; then
        log_error "Arquivo não encontrado: $1"
        log_error "$2"
        exit 1
    fi
}

read_cred() {
    # read_cred <arquivo> <chave>
    sudo grep "^$2=" "$1" | cut -d= -f2-
}

if $DRY_RUN; then
    log_warn "Dry-run: nenhuma escrita será feita no Vault."
fi

log_info "Lendo credenciais de $DATA_BASE/{redis,minio,kafka}/.bootstrap-creds..."
require_file "$DATA_BASE/redis/.bootstrap-creds" "Rodar setup-redis.sh primeiro (Task #406)."
require_file "$DATA_BASE/minio/.bootstrap-creds" "Rodar setup-minio.sh primeiro (Task #407)."
require_file "$DATA_BASE/kafka/.bootstrap-creds" "Rodar setup-kafka.sh primeiro (Task #408)."
require_file "$KAFKA_CA_CERT" "CA cert do Kafka ausente — setup-kafka.sh deveria tê-lo gerado."
require_file "$DATA_BASE/vault/.bootstrap-creds.json" "Vault ainda não inicializado (Task #409)."

redis_pw=$(read_cred "$DATA_BASE/redis/.bootstrap-creds" default_pw)
minio_user=$(read_cred "$DATA_BASE/minio/.bootstrap-creds" root_user)
minio_pw=$(read_cred "$DATA_BASE/minio/.bootstrap-creds" root_pw)
kafka_pw=$(read_cred "$DATA_BASE/kafka/.bootstrap-creds" admin_pw)
vault_root_token=$(sudo python3 -c "import json,sys; print(json.load(open('$DATA_BASE/vault/.bootstrap-creds.json'))['root_token'])")

for var in redis_pw minio_user minio_pw kafka_pw vault_root_token; do
    if [[ -z "${!var}" ]]; then
        log_error "$var vazio — abortando (fonte de verdade incompleta)."
        exit 1
    fi
done

log_info "Recuperando client_secrets M2M do Keycloak (deploy/$KEYCLOAK_DEPLOYMENT -n $KEYCLOAK_NAMESPACE)..."
declare -A client_secrets
for client in uniplus-api-selecao uniplus-api-portal uniplus-api-ingresso; do
    if $DRY_RUN; then
        log_warn "Dry-run: client_secret de $client seria recuperado via kcadm.sh"
        client_secrets[$client]="DRY-RUN-PLACEHOLDER"
        continue
    fi
    secret=$("${KUBECTL[@]}" exec -n "$KEYCLOAK_NAMESPACE" "deploy/$KEYCLOAK_DEPLOYMENT" -- bash -c "
        /opt/keycloak/bin/kcadm.sh config credentials \
            --server http://localhost:8080/auth --realm master \
            --user \"\$KC_BOOTSTRAP_ADMIN_USERNAME\" --password \"\$KC_BOOTSTRAP_ADMIN_PASSWORD\" >/dev/null
        CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r $KEYCLOAK_REALM -q clientId=$client --fields id --format csv --noquotes | tail -1)
        /opt/keycloak/bin/kcadm.sh get clients/\$CID/client-secret -r $KEYCLOAK_REALM --fields value --format csv --noquotes | tail -1
    " 2>/dev/null)
    if [[ -z "$secret" ]]; then
        log_error "client_secret de $client veio vazio — client existe no realm $KEYCLOAK_REALM?"
        exit 1
    fi
    client_secrets[$client]="$secret"
    log_success "client_secret de $client recuperado (${secret:0:8}...)"
done

if $DRY_RUN; then
    log_warn "Dry-run: os seguintes paths seriam escritos no Vault:"
    log_warn "  secret/standalone/redis/default"
    log_warn "  secret/standalone/minio/root"
    log_warn "  secret/standalone/kafka/admin (+ ca_cert)"
    for client in "${!client_secrets[@]}"; do
        log_warn "  secret/standalone/keycloak/clients/$client"
    done
    log_warn "Dry-run: secret/standalone/postgres/{selecao,portal,ingresso} NÃO cobertos por este script (ver header)."
    exit 0
fi

# Segredos nunca em argv de kubectl/vault (visível via ps/proc enquanto o
# comando roda) — cada valor vai para um arquivo em diretório temporário
# 700/600, copiado para o pod e consumido via `campo=@arquivo` do Vault CLI.
# Mesmo padrão já usado para o ca_cert e para o fix do MinIO (Task #407).
tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
trap 'shred -u "$tmpdir"/* 2>/dev/null; rm -rf "$tmpdir"' EXIT

printf '%s' "$vault_root_token" > "$tmpdir/vault_token"
printf '%s' "$redis_pw" > "$tmpdir/redis_pw"
printf '%s' "$minio_user" > "$tmpdir/minio_user"
printf '%s' "$minio_pw" > "$tmpdir/minio_pw"
printf '%s' "$kafka_pw" > "$tmpdir/kafka_pw"
printf '%s' "${client_secrets[uniplus-api-selecao]}" > "$tmpdir/oidc_selecao"
printf '%s' "${client_secrets[uniplus-api-portal]}" > "$tmpdir/oidc_portal"
printf '%s' "${client_secrets[uniplus-api-ingresso]}" > "$tmpdir/oidc_ingresso"
cp "$KAFKA_CA_CERT" "$tmpdir/ca_crt" 2>/dev/null || sudo cp "$KAFKA_CA_CERT" "$tmpdir/ca_crt"
chmod 600 "$tmpdir"/*

log_info "Copiando arquivos temporários para dentro do pod $VAULT_POD..."
"${KUBECTL[@]}" exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- mkdir -p /tmp/vault-seed
"${KUBECTL[@]}" cp "$tmpdir/." "$VAULT_NAMESPACE/$VAULT_POD:/tmp/vault-seed"

log_info "Escrevendo secrets no Vault ($VAULT_NAMESPACE/$VAULT_POD)..."
"${KUBECTL[@]}" exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh <<'REMOTE_SCRIPT'
set -e
export VAULT_TOKEN="$(cat /tmp/vault-seed/vault_token)"

vault kv put secret/standalone/redis/default \
    password=@/tmp/vault-seed/redis_pw >/dev/null

vault kv put secret/standalone/minio/root \
    username=@/tmp/vault-seed/minio_user \
    password=@/tmp/vault-seed/minio_pw >/dev/null

vault kv put secret/standalone/kafka/admin \
    username=admin \
    password=@/tmp/vault-seed/kafka_pw \
    ca_cert=@/tmp/vault-seed/ca_crt >/dev/null

vault kv put secret/standalone/keycloak/clients/uniplus-api-selecao \
    client_secret=@/tmp/vault-seed/oidc_selecao >/dev/null

vault kv put secret/standalone/keycloak/clients/uniplus-api-portal \
    client_secret=@/tmp/vault-seed/oidc_portal >/dev/null

vault kv put secret/standalone/keycloak/clients/uniplus-api-ingresso \
    client_secret=@/tmp/vault-seed/oidc_ingresso >/dev/null

rm -rf /tmp/vault-seed
REMOTE_SCRIPT

unset redis_pw minio_user minio_pw kafka_pw vault_root_token client_secrets

log_success "Secrets populados no Vault: redis/default, minio/root, kafka/admin, keycloak/clients/uniplus-api-{selecao,portal,ingresso}."
log_warn "secret/standalone/postgres/{selecao,portal,ingresso} pendente — populado dentro das Tasks #412/#413/#414."
