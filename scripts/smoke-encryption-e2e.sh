#!/usr/bin/env bash
# shellcheck shell=bash
#
# Smoke E2E para validar que a uniplus-api consome Vault Transit em standalone
# (uniplus-infra#220). O script:
#
#   1. Obtém um token OIDC do realm `uniplus` via apicurio-registry client
#      (directAccessGrantsEnabled=true documentado em
#      configs/uniplus-standalone/11-uniplus-apis.md).
#   2. Envia POST /api/v1/selecao/editais com header `Idempotency-Key`
#      contendo um UUID v4 (mais portável que v7 em sh) — força a uniplus-api
#      a invocar o `IdempotencyFilter`, que toca o `IUniPlusEncryptionService`.
#   3. Espera HTTP 201 (criado) ou 422 (validation falhou pelo payload mínimo).
#      Códigos 5xx indicam regressão (Provider mal configurado ou Vault down).
#   4. Lê o audit log do Vault no Pod do standalone e procura por entradas
#      `request.path=transit/encrypt/uniplus-idempotency-aesgcm` emitidas
#      DEPOIS do timestamp registrado antes do POST — comprova que a request
#      atual (não uma anterior) tocou o Vault.
#
# Idempotente: cada execução gera um Idempotency-Key novo e o filtro do Vault
# pelos últimos 60s descarta runs anteriores.

set -euo pipefail

# Defaults — sobrescrevíveis via env vars
API_HOST="${API_HOST:-api-selecao.standalone.portaluni.com.br}"
API_PATH="${API_PATH:-/api/v1/selecao/editais}"
KEYCLOAK_BASE="${KEYCLOAK_BASE:-https://standalone.portaluni.com.br/auth/realms/uniplus}"
KEYCLOAK_CLIENT_ID="${KEYCLOAK_CLIENT_ID:-apicurio-registry}"
SSH_HOST="${SSH_HOST:-ubuntu@164.152.53.29}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
VAULT_POD_NS="${VAULT_POD_NS:-vault}"
VAULT_POD_NAME="${VAULT_POD_NAME:-platform-vault-uniplus-standalone-0}"
TRANSIT_KEY="${TRANSIT_KEY:-uniplus-idempotency-aesgcm}"
AUDIT_LOG_PATH="${AUDIT_LOG_PATH:-/vault/audit/audit.log}"

log() {
    printf '%s [smoke-encryption] %s\n' "$(date -u +%H:%M:%S)" "$1" >&2
}

fail() {
    log "ERRO: $1"
    exit 1
}

# Credenciais devem vir SEM hardcode — operador exporta antes de rodar.
: "${KEYCLOAK_CLIENT_SECRET:?KEYCLOAK_CLIENT_SECRET é obrigatório (apicurio-registry client_secret no realm uniplus)}"
: "${KEYCLOAK_USERNAME:?KEYCLOAK_USERNAME é obrigatório (usuário no realm uniplus com directAccessGrants permitido)}"
: "${KEYCLOAK_PASSWORD:?KEYCLOAK_PASSWORD é obrigatório}"
# Token Vault necessário para listar audit devices (/sys/audit exige token
# com `sudo` capability — root ou policy dedicada). Permanece em var
# separada para que o operador rotacione independentemente do KEYCLOAK_*.
: "${VAULT_TOKEN_FOR_AUDIT:?VAULT_TOKEN_FOR_AUDIT é obrigatório (Vault token com capability sudo em sys/audit; tipicamente root token em standalone). Exportar antes de rodar.}"

command -v curl >/dev/null 2>&1 || fail "curl não encontrado"
command -v jq >/dev/null 2>&1 || fail "jq não encontrado"
command -v uuidgen >/dev/null 2>&1 || fail "uuidgen não encontrado"
command -v ssh >/dev/null 2>&1 || fail "ssh não encontrado"

# --- 1. Obter token OIDC ---------------------------------------------------

log "Obtendo token OIDC para client=${KEYCLOAK_CLIENT_ID} user=${KEYCLOAK_USERNAME}"

# `--data-urlencode` é obrigatório aqui: senhas/secrets podem conter `&`,
# `=`, `+` ou `%` que `curl -d` envia literalmente, corrompendo o form e
# gerando 401 enganoso. URL-encode garante que credenciais com caracteres
# especiais sejam transmitidas íntegras.
token_response=$(curl -sk -X POST \
    "${KEYCLOAK_BASE}/protocol/openid-connect/token" \
    --data-urlencode "grant_type=password" \
    --data-urlencode "client_id=${KEYCLOAK_CLIENT_ID}" \
    --data-urlencode "client_secret=${KEYCLOAK_CLIENT_SECRET}" \
    --data-urlencode "username=${KEYCLOAK_USERNAME}" \
    --data-urlencode "password=${KEYCLOAK_PASSWORD}" \
    --data-urlencode "scope=openid")

access_token=$(echo "$token_response" | jq -r .access_token)

if [ -z "$access_token" ] || [ "$access_token" = "null" ]; then
    log "Falha ao obter token. Resposta do Keycloak:"
    echo "$token_response" | jq . >&2 || echo "$token_response" >&2
    fail "Sem access_token"
fi

# Validar audience inclui 'uniplus' (sem isso a API rejeita 401).
# JWT segments são base64url (caracteres -/_ em vez de +/) e podem vir sem
# padding. GNU base64 -d exige base64 standard e múltiplo de 4 bytes:
# normalizamos antes de decodificar para evitar exit não-zero do `base64`
# que sob `set -euo pipefail` abortaria o script.
decode_jwt_segment() {
    local seg="$1"
    # base64url → base64 standard
    seg=$(printf '%s' "$seg" | tr -- '-_' '+/')
    # padding para múltiplo de 4
    local mod=$(( ${#seg} % 4 ))
    if [ "$mod" -ne 0 ]; then
        seg="${seg}$(printf '%*s' $((4 - mod)) '' | tr ' ' '=')"
    fi
    printf '%s' "$seg" | base64 -d 2>/dev/null
}

jwt_payload=$(printf '%s' "$access_token" | cut -d. -f2)
audiences=$(decode_jwt_segment "$jwt_payload" | jq -r '.aud | if type=="array" then join(",") else . end' 2>/dev/null || echo "")

if [ -z "$audiences" ]; then
    fail "Falha ao decodificar payload do JWT (segmento base64url do access_token). Token recebido começa com: ${access_token:0:30}..."
fi

case ",$audiences," in
    *,uniplus,*) ;;
    *) fail "Token não tem audience 'uniplus' (audiences=$audiences). Verificar audience mapper no client ${KEYCLOAK_CLIENT_ID}." ;;
esac

log "Token OIDC obtido com audience=${audiences}"

# --- 2. Marcar timestamp ANTES do POST -------------------------------------

# O audit log é JSON-lines com campo `time` em RFC3339 com fração de segundo
# (`2026-05-11T11:21:45.123Z`). Comparação lexicográfica falha porque `.`
# < `Z` em ASCII — `.123Z` ordena ANTES de `Z` puro, então entradas válidas
# emitidas no mesmo segundo do POST seriam descartadas. Usamos epoch numérico
# (segundo inteiro, com 1s de slack para absorver clock drift entre o
# host local e o pod do Vault) e o jq converte `.time` removendo fração
# antes de `fromdate`.
since_epoch_minus_1=$(( $(date -u +%s) - 1 ))

# --- 3. POST /api/v1/selecao/editais com Idempotency-Key -------------------

idempotency_key=$(uuidgen)
log "POST https://${API_HOST}${API_PATH} Idempotency-Key=${idempotency_key}"

# Payload mínimo — a validação do payload pode falhar (422), o que ainda assim
# exercita o IdempotencyFilter (cifragem). 5xx é regressão real.
payload='{
  "numero": "SMOKE-2026-001",
  "ano": 2026,
  "titulo": "Smoke encryption E2E (uniplus-infra#220)"
}'

http_status=$(curl -sk -o /tmp/smoke-api-response.json -w '%{http_code}' \
    -X POST "https://${API_HOST}${API_PATH}" \
    -H "Authorization: Bearer ${access_token}" \
    -H "Content-Type: application/json" \
    -H "Idempotency-Key: ${idempotency_key}" \
    --data "$payload")

case "$http_status" in
    201|422)
        log "POST retornou ${http_status} (esperado — pipeline de cifragem foi exercitado)"
        ;;
    401|403)
        log "POST retornou ${http_status} (auth falhou — não dá pra validar cifragem). Body:"
        cat /tmp/smoke-api-response.json >&2 || true
        fail "Falha de auth não diagnostica este smoke"
        ;;
    5*)
        log "POST retornou ${http_status} (provavelmente Provider mal configurado ou Vault down). Body:"
        cat /tmp/smoke-api-response.json >&2 || true
        fail "5xx na request — regressão"
        ;;
    *)
        log "POST retornou ${http_status} inesperado. Body:"
        cat /tmp/smoke-api-response.json >&2 || true
        fail "HTTP status inesperado"
        ;;
esac

# --- 4. Verificar audit log do Vault --------------------------------------
#
# Estratégia: chamar `vault audit list` para diferenciar "Vault inacessível"
# de "audit device desabilitado". Em sucesso, ler audit log e filtrar por
# entradas posteriores a $since_iso (lexicografic compare em RFC3339 funciona).

log "Procurando entrada transit/encrypt/${TRANSIT_KEY} no audit log desde epoch=${since_epoch_minus_1}"

# `set +e` localmente para distinguir erros de SSH/kubectl (rc!=0) de
# "comando rodou mas devolveu vazio" (audit ausente).
# VAULT_TOKEN_FOR_AUDIT é expandido AQUI (no shell local) — checado via `:?`
# no topo do script. Sem esse expand a env var ficaria vazia dentro do
# kubectl exec porque o shell remoto não tem a mesma var disponível.
set +e
audit_devices=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 "$SSH_HOST" "
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n ${VAULT_POD_NS} exec -i ${VAULT_POD_NAME} -- \
  env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=${VAULT_TOKEN_FOR_AUDIT} \
  vault audit list -format=json
" 2>&1)
audit_rc=$?
set -e

if [ "$audit_rc" -ne 0 ]; then
    log "ERRO: falha ao consultar Vault via SSH/kubectl (rc=${audit_rc}). Output:"
    echo "$audit_devices" | head -10 >&2
    log "Verificar: (1) VAULT_TOKEN_FOR_AUDIT tem capability sudo em sys/audit; (2) SSH/kubectl funcionando; (3) Vault unsealed."
    fail "Comunicação com o Vault falhou"
fi

# Vault retorna `{}` (objeto vazio) ou `null` quando não há audit devices.
if [ -z "$audit_devices" ] \
    || echo "$audit_devices" | jq -e 'if type == "object" then (length == 0) else (. == null) end' >/dev/null 2>&1; then
    log "WARN: Vault está acessível, mas não tem audit devices habilitados."
    log "Para habilitar: kubectl exec -i ${VAULT_POD_NAME} -n ${VAULT_POD_NS} -- vault audit enable file file_path=${AUDIT_LOG_PATH}"
    log "Pulando verificação do audit log — POST retornou ${http_status} mas não dá pra confirmar transit/encrypt sem audit."
    log "RESULTADO: HTTP ${http_status} (OK); audit verification pulada (Vault sem audit device)."
    exit 0
fi

# Audit habilitado — buscar entrada DEPOIS de $since_epoch_minus_1 usando
# jq para parsear JSON-lines, converter `.time` (RFC3339 com fração) em
# epoch removendo fração com sub() e comparar numericamente com >=.
# tail -500 dá folga para bursts de tráfego concorrente.
set +e
audit_hits=$(ssh -i "$SSH_KEY" -o ConnectTimeout=10 "$SSH_HOST" "
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n ${VAULT_POD_NS} exec -i ${VAULT_POD_NAME} -- \
  sh -c 'tail -500 ${AUDIT_LOG_PATH}'
" 2>/dev/null | jq -c \
    --argjson since "$since_epoch_minus_1" \
    --arg path "transit/encrypt/${TRANSIT_KEY}" \
    'select((.time | sub("\\.[0-9]+Z$"; "Z") | fromdate) >= $since and .request.path == $path)')
hits_rc=$?
set -e

if [ "$hits_rc" -ne 0 ] || [ -z "$audit_hits" ]; then
    log "ERRO: nenhuma entrada transit/encrypt/${TRANSIT_KEY} no audit log emitida APÓS epoch=${since_epoch_minus_1}"
    log "Verificar:"
    log "  - log do pod uniplus-api-selecao mostra Provider=vault"
    log "  - role uniplus-api existe com bound_service_account_names contendo uniplus-api-selecao"
    log "  - audit log file ${AUDIT_LOG_PATH} acessível e sendo gravado"
    fail "Audit log sem evidência de transit/encrypt na janela atual"
fi

log "Audit log confirma uso do Vault Transit:"
echo "$audit_hits" | jq -r '"  \(.time) \(.request.path) (op=\(.request.operation))"'

log "OK — smoke E2E verde: HTTP ${http_status} + transit/encrypt no audit do Vault (após epoch=${since_epoch_minus_1})"
