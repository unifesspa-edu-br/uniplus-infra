#!/usr/bin/env bash
# Prepara o Vault de produção, depois de inicializado e aberto, para o External
# Secrets: monta um KV v2 por sistema e ambiente (uniplus-<amb>, geo-<amb>,
# plataforma-<amb>), habilita a autenticação Kubernetes e cria, para cada sistema,
# uma política de leitura só no próprio KV e uma role ligada à ServiceAccount da
# ClusterSecretStore correspondente. Um sistema não lê o KV do outro. Cria também o
# Transit de cada sistema, com as chaves e as políticas e roles das APIs que cifram
# (lib-transit.sh). Antes de tudo habilita a auditoria, para que nenhum segredo
# seja gravado sem rastro. Idempotente: o que já existe é reaplicado sem erro.
#
# Uso: [AMBIENTE=prd|hml] [VAULT_URL=...] ./configurar-vault.sh [--dry-run]
# Rodar antes de semear-vault.sh, de qualquer máquina com o token raiz do Vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"
# shellcheck source=lib-transit.sh
source "$SCRIPT_DIR/lib-transit.sh"

SISTEMAS=(uniplus geo plataforma)
# KV sem store: guarda o original dos segredos do Keycloak institucional, que roda
# fora do cluster e os recebe do pipeline dele (docs/vault-caminhos.md).
KV_SEM_STORE=(oidc)

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

# Dois destinos de auditoria: com um só, a falha dele faz o Vault recusar todas as
# requisições. O arquivo fica no volume de auditoria do chart, rotacionado pelo
# sidecar audit-rotate; a saída padrão do pod é rotacionada pelo kubelet.
AUDITORIA=("stdout:stdout" "file:/vault/audit/audit.log")

# Imprime o file_path do device de auditoria habilitado no caminho: vazio se não há
# device, "?" se o device não é do tipo file.
destino_da_auditoria() {
    CAMINHO="$1/" python3 -c '
import json, os, sys
resposta = json.load(sys.stdin)
device = resposta.get("data", resposta).get(os.environ["CAMINHO"])
if device is None:
    print("")
elif device.get("type") != "file":
    print("?")
else:
    print(device.get("options", {}).get("file_path", "?"))
' <"$VAULT_BODY_FILE"
}

habilitar_auditoria() {
    local item caminho destino
    for item in "${AUDITORIA[@]}"; do
        caminho="${item%%:*}" destino="${item#*:}"
        exigir_sucesso GET sys/audit
        case "$(destino_da_auditoria "$caminho")" in
            "$destino")
                log_success "Auditoria $caminho/ já habilitada."
                continue ;;
            "") ;;
            *)
                log_error "Auditoria $caminho/ existe com outro destino; conferir com vault audit list -detailed."
                exit 1 ;;
        esac
        exigir_sucesso PUT "sys/audit/$caminho" \
            "{\"type\":\"file\",\"options\":{\"file_path\":\"$destino\"}}"
        log_success "Auditoria $caminho/ habilitada ($destino)."
    done
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

# Snapshot do Raft feito pelo pipeline antes de uma migration. A política só lê o
# snapshot, sem acesso a KV nem a Transit. O pipeline entra pelo AppRole com
# role_id e secret_id (variáveis protegidas do repositório de implantação, ver
# RUNBOOKS, seção 3) e recebe um token curto a cada backup: nada vence entre
# uma implantação e outra.
POLITICA_SNAPSHOT="uniplus-backup-snapshot"

criar_acesso_de_snapshot() {
    exigir_sucesso PUT "sys/policies/acl/$POLITICA_SNAPSHOT" \
        '{"policy":"path \"sys/storage/raft/snapshot\" { capabilities = [\"read\"] }"}'
    vault_api GET sys/auth
    if ! grep -q '"approle/"' "$VAULT_BODY_FILE"; then
        exigir_sucesso POST sys/auth/approle '{"type":"approle"}'
    fi
    exigir_sucesso POST "auth/approle/role/$POLITICA_SNAPSHOT" \
        "{\"token_policies\":\"$POLITICA_SNAPSHOT\",\"token_no_default_policy\":true,\"token_ttl\":\"15m\",\"token_max_ttl\":\"30m\",\"secret_id_ttl\":\"0\",\"token_num_uses\":0}"
    log_success "Política e AppRole $POLITICA_SNAPSHOT aplicadas."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    for sistema in "${SISTEMAS[@]}"; do
        echo "[DRY-RUN] montaria $sistema-$AMBIENTE/ (KV v2) e aplicaria a política e a role external-secrets-$sistema em $VAULT_URL"
    done
    for sistema in "${KV_SEM_STORE[@]}"; do
        echo "[DRY-RUN] montaria $sistema-$AMBIENTE/ (KV v2), sem política nem role, em $VAULT_URL"
    done
    echo "[DRY-RUN] habilitaria a auditoria em stdout/ e em file/ (/vault/audit/audit.log)"
    echo "[DRY-RUN] habilitaria auth/kubernetes"
    echo "[DRY-RUN] aplicaria a política e o AppRole $POLITICA_SNAPSHOT (só lê sys/storage/raft/snapshot)"
    echo "[DRY-RUN] montaria o Transit $MOUNT_UNIPLUS, $MOUNT_GEO e $MOUNT_PLATAFORMA com as chaves e a política e a role de $SA_API_HOST e $SA_GEO"
    exit 0
fi
preparar_provisionamento
habilitar_auditoria
habilitar_auth_kubernetes
for sistema in "${SISTEMAS[@]}"; do
    montar_kv "$sistema-$AMBIENTE"
    criar_politica_e_role "$sistema" "$sistema-$AMBIENTE"
done
for sistema in "${KV_SEM_STORE[@]}"; do
    montar_kv "$sistema-$AMBIENTE"
done
configurar_transit
criar_acesso_de_snapshot
