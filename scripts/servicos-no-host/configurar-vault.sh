#!/usr/bin/env bash
# Prepara o Vault de produção, depois de inicializado e aberto, para o External
# Secrets: monta o KV v2 em `secret/`, habilita a autenticação Kubernetes, e cria a
# política e a role que o ClusterSecretStore usa. Idempotente: o que já existe é
# reaplicado sem erro.
#
# Uso: [VAULT_URL=...] ./configurar-vault.sh [--dry-run]
# Rodar antes de semear-vault.sh, de qualquer máquina com o token raiz do Vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

ROLE_ESO="external-secrets"
POLITICA_ESO="external-secrets-read"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

# Executa uma chamada que precisa dar 2xx; qualquer outro código aborta.
exigir_sucesso() {
    vault_api "$@"
    [[ "$VAULT_HTTP_STATUS" =~ ^2 ]] || {
        log_error "Vault respondeu HTTP $VAULT_HTTP_STATUS em $2."
        exit 1
    }
}

montar_kv() {
    vault_api GET sys/mounts
    if grep -q '"secret/"' "$VAULT_BODY_FILE"; then
        log_success "Mount secret/ já existe."
    else
        exigir_sucesso POST sys/mounts/secret '{"type":"kv","options":{"version":"2"}}'
        log_success "Mount secret/ (KV v2) criado."
    fi
}

habilitar_auth_kubernetes() {
    vault_api GET sys/auth
    if grep -q '"kubernetes/"' "$VAULT_BODY_FILE"; then
        log_success "Auth kubernetes/ já habilitada."
    else
        exigir_sucesso POST sys/auth/kubernetes '{"type":"kubernetes"}'
        log_success "Auth kubernetes/ habilitada."
    fi
    exigir_sucesso POST auth/kubernetes/config \
        '{"kubernetes_host":"https://kubernetes.default.svc.cluster.local"}'
}

criar_politica_e_role() {
    local politica
    politica='path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read"] }'
    exigir_sucesso PUT "sys/policies/acl/$POLITICA_ESO" \
        "$(POLITICA="$politica" python3 -c 'import json, os; print(json.dumps({"policy": os.environ["POLITICA"]}))')"
    exigir_sucesso POST "auth/kubernetes/role/$ROLE_ESO" \
        "{\"bound_service_account_names\":\"external-secrets\",\"bound_service_account_namespaces\":\"external-secrets\",\"policies\":\"$POLITICA_ESO\",\"ttl\":\"1h\"}"
    log_success "Política $POLITICA_ESO e role $ROLE_ESO aplicadas."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] montaria secret/ (KV v2), habilitaria auth/kubernetes e aplicaria a política $POLITICA_ESO e a role $ROLE_ESO em $VAULT_URL"
    exit 0
fi
preparar_provisionamento
montar_kv
habilitar_auth_kubernetes
criar_politica_e_role
