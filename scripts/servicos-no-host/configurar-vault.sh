#!/usr/bin/env bash
# Prepara o Vault de produção, depois de inicializado e aberto, para o External
# Secrets: monta um KV v2 por sistema e ambiente (uniplus-<amb>, geo-<amb>,
# plataforma-<amb>), habilita a autenticação Kubernetes e cria, para cada sistema,
# uma política de leitura só no próprio KV e uma role ligada à ServiceAccount da
# ClusterSecretStore correspondente. Um sistema não lê o KV do outro. Idempotente:
# o que já existe é reaplicado sem erro.
#
# Uso: [AMBIENTE=prd|hml] [VAULT_URL=...] ./configurar-vault.sh [--dry-run]
# Rodar antes de semear-vault.sh, de qualquer máquina com o token raiz do Vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

SISTEMAS=(uniplus geo plataforma)

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

# Monta o KV v2 do sistema, se ainda não existe.
montar_kv() {
    local kv="$1"
    vault_api GET sys/mounts
    if grep -q "\"$kv/\"" "$VAULT_BODY_FILE"; then
        log_success "Mount $kv/ já existe."
    else
        exigir_sucesso POST "sys/mounts/$kv" '{"type":"kv","options":{"version":"2"}}'
        log_success "Mount $kv/ (KV v2) criado."
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

# Política de leitura só no KV do sistema e role da ServiceAccount da store.
criar_politica_e_role() {
    local sistema="$1" kv="$2" papel politica
    papel="external-secrets-$sistema"
    politica="path \"$kv/data/*\" { capabilities = [\"read\"] }
path \"$kv/metadata/*\" { capabilities = [\"read\"] }"
    exigir_sucesso PUT "sys/policies/acl/$papel" \
        "$(POLITICA="$politica" python3 -c 'import json, os; print(json.dumps({"policy": os.environ["POLITICA"]}))')"
    exigir_sucesso POST "auth/kubernetes/role/$papel" \
        "{\"bound_service_account_names\":\"$papel\",\"bound_service_account_namespaces\":\"external-secrets\",\"policies\":\"$papel\",\"ttl\":\"1h\"}"
    log_success "Política e role $papel aplicadas ao KV $kv."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    for sistema in "${SISTEMAS[@]}"; do
        echo "[DRY-RUN] montaria $sistema-$AMBIENTE/ (KV v2) e aplicaria a política e a role external-secrets-$sistema em $VAULT_URL"
    done
    echo "[DRY-RUN] habilitaria auth/kubernetes"
    exit 0
fi
preparar_provisionamento
habilitar_auth_kubernetes
for sistema in "${SISTEMAS[@]}"; do
    montar_kv "$sistema-$AMBIENTE"
    criar_politica_e_role "$sistema" "$sistema-$AMBIENTE"
done
