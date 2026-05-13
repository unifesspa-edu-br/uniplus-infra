#!/usr/bin/env bash
# shellcheck shell=bash
#
# Smoke E2E do pipeline metrics OTLP → Prometheus (uniplus-infra#247).
#
# O script:
#   1. Abre port-forward local para o Prometheus standalone
#   2. Gera tráfego controlado contra as 3 APIs Uni+ (health checks + chamadas
#      não-autenticadas) para alimentar as métricas http_server_*
#   3. Aguarda o pipeline OTelCol → prometheusremotewrite → TSDB convergir
#   4. Valida 3 expressões PromQL no Prometheus
#   5. Verifica cardinalidade de séries http_server_*
#   6. Identifica endpoints com http_route="<unset>"
#   7. Persiste saída em docs/validacao/metrics-pipeline-$(date +%Y-%m-%d).md
#
# Pré-requisitos:
#   - kubectl configurado para o cluster standalone (kubeconfig local ou via SSH)
#   - curl, jq
#   - hey (opcional; usa loop curl como fallback se ausente)
#
# Uso:
#   ./scripts/smoke-metrics-pipeline.sh
#   WAIT_SECS=120 ./scripts/smoke-metrics-pipeline.sh
#   SKIP_TRAFFIC=true ./scripts/smoke-metrics-pipeline.sh   # só PromQL, sem gerar tráfego
#
# Variáveis de ambiente:
#   PROM_NS            Namespace do Prometheus (default: observability-prometheus)
#   PROM_SVC           Service do Prometheus   (default: platform-observability-pro-prometheus)
#   PROM_LOCAL_PORT    Porta local do port-forward (default: 19090)
#   API_PORTAL_HOST    URL base da API portal   (default: https://api-portal.standalone.portaluni.com.br)
#   API_SELECAO_HOST   URL base da API seleção  (default: https://api-selecao.standalone.portaluni.com.br)
#   API_INGRESSO_HOST  URL base da API ingresso (default: https://api-ingresso.standalone.portaluni.com.br)
#   HEALTH_PATH        Path do health endpoint  (default: /health)
#   UNAUTH_PATH        Path do endpoint autenticado p/ teste 401 (default: /api/v1/selecao/editais)
#   TRAFFIC_TOTAL      Total de requests por API (default: 200)
#   TRAFFIC_WORKERS    Nº de workers paralelos   (default: 10)
#   WAIT_SECS          Segundos de espera pós-tráfego (default: 75)
#   SKIP_TRAFFIC       Se "true", pula geração de tráfego (default: false)
#   SKIP_TLS_VERIFY    Se "true", passa --insecure ao curl (default: false)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuração ──────────────────────────────────────────────────────────────
PROM_NS="${PROM_NS:-observability-prometheus}"
PROM_SVC="${PROM_SVC:-platform-observability-pro-prometheus}"
PROM_LOCAL_PORT="${PROM_LOCAL_PORT:-19090}"
PROM_URL="http://localhost:${PROM_LOCAL_PORT}"

API_PORTAL_HOST="${API_PORTAL_HOST:-https://api-portal.standalone.portaluni.com.br}"
API_SELECAO_HOST="${API_SELECAO_HOST:-https://api-selecao.standalone.portaluni.com.br}"
API_INGRESSO_HOST="${API_INGRESSO_HOST:-https://api-ingresso.standalone.portaluni.com.br}"

HEALTH_PATH="${HEALTH_PATH:-/health}"
UNAUTH_PATH="${UNAUTH_PATH:-/api/v1/selecao/editais}"

TRAFFIC_TOTAL="${TRAFFIC_TOTAL:-200}"
TRAFFIC_WORKERS="${TRAFFIC_WORKERS:-10}"

WAIT_SECS="${WAIT_SECS:-75}"
SKIP_TRAFFIC="${SKIP_TRAFFIC:-false}"

# Array de flags extras para curl (SC2086-safe)
CURL_EXTRA_FLAGS=()
if [ "${SKIP_TLS_VERIFY:-false}" = "true" ]; then
    CURL_EXTRA_FLAGS=("--insecure")
fi

VALIDACAO_DIR="${REPO_ROOT}/docs/validacao"
OUTPUT_FILE="${VALIDACAO_DIR}/metrics-pipeline-$(date +%Y-%m-%d).md"

# ── Logging ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { printf '%s [smoke-metrics] %s\n'       "$(date -u +%H:%M:%SZ)" "$1" >&2; }
log_ok()  { printf "%b[ OK ]%b %s\n"   "$GREEN" "$NC" "$1" >&2; }
log_err() { printf "%b[FAIL]%b %s\n"   "$RED"   "$NC" "$1" >&2; }
log_warn(){ printf "%b[WARN]%b %s\n"   "$YELLOW" "$NC" "$1" >&2; }
fail()    { log_err "$1"; exit 1; }

# ── Pré-requisitos ────────────────────────────────────────────────────────────
log "Verificando pré-requisitos..."
command -v curl    >/dev/null 2>&1 || fail "curl não encontrado"
command -v jq      >/dev/null 2>&1 || fail "jq não encontrado"
command -v kubectl >/dev/null 2>&1 || fail "kubectl não encontrado"

HAS_HEY=false
if command -v hey >/dev/null 2>&1; then
    HAS_HEY=true
    log "hey encontrado — usando para geração de tráfego"
else
    log_warn "hey não encontrado — fallback para loop curl (instale 'hey' para 100 RPS precisos)"
fi

mkdir -p "$VALIDACAO_DIR"

# ── Port-forward ──────────────────────────────────────────────────────────────
PORTFWD_PID=""

cleanup() {
    if [ -n "$PORTFWD_PID" ] && kill -0 "$PORTFWD_PID" 2>/dev/null; then
        log "Encerrando port-forward (pid=$PORTFWD_PID)"
        kill "$PORTFWD_PID" 2>/dev/null || true
        wait "$PORTFWD_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

log "Abrindo port-forward: svc/${PROM_SVC} -n ${PROM_NS} → localhost:${PROM_LOCAL_PORT}"
kubectl port-forward \
    -n "$PROM_NS" \
    "svc/${PROM_SVC}" \
    "${PROM_LOCAL_PORT}:9090" \
    >/dev/null 2>&1 &
PORTFWD_PID=$!

# Aguardar o port-forward ficar pronto (até 15s)
for i in $(seq 1 15); do
    if curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" "${PROM_URL}/-/healthy" >/dev/null 2>&1; then
        log_ok "Prometheus acessível em ${PROM_URL}"
        break
    fi
    if [ "$i" -eq 15 ]; then
        fail "Port-forward não ficou pronto em 15s. Verificar: kubectl get svc -n ${PROM_NS}"
    fi
    sleep 1
done

# ── Geração de tráfego ────────────────────────────────────────────────────────
generate_load_hey() {
    local host="$1" path="$2" count="$3" concurrency="$4"
    hey -n "$count" -c "$concurrency" -q 7 "${host}${path}" >/dev/null 2>&1 || true
}

generate_load_curl() {
    local host="$1" path="$2" count="$3" concurrency="$4"
    local per_worker=$(( count / concurrency + 1 ))
    local pids=()
    for (( w=0; w<concurrency; w++ )); do
        (for (( r=0; r<per_worker; r++ )); do
            curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
                -o /dev/null -w '' "${host}${path}" 2>/dev/null || true
        done) &
        pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
}

generate_load() {
    local host="$1" path="$2" count="${3:-$TRAFFIC_TOTAL}" concurrency="${4:-$TRAFFIC_WORKERS}"
    if [ "$HAS_HEY" = "true" ]; then
        generate_load_hey "$host" "$path" "$count" "$concurrency"
    else
        generate_load_curl "$host" "$path" "$count" "$concurrency"
    fi
}

if [ "$SKIP_TRAFFIC" = "true" ]; then
    log_warn "SKIP_TRAFFIC=true — pulando geração de tráfego"
else
    log "Gerando tráfego (${TRAFFIC_TOTAL} req × 3 APIs health + 50 req 401)..."

    # Health checks em paralelo — 200 requests × 3 APIs
    generate_load "$API_PORTAL_HOST"   "$HEALTH_PATH"  "$TRAFFIC_TOTAL" "$TRAFFIC_WORKERS" &
    PID_PORTAL=$!
    generate_load "$API_SELECAO_HOST"  "$HEALTH_PATH"  "$TRAFFIC_TOTAL" "$TRAFFIC_WORKERS" &
    PID_SELECAO=$!
    generate_load "$API_INGRESSO_HOST" "$HEALTH_PATH"  "$TRAFFIC_TOTAL" "$TRAFFIC_WORKERS" &
    PID_INGRESSO=$!

    # 50 requests não-autenticadas (espera-se 401) — exercita http_route sem bearer
    generate_load "$API_PORTAL_HOST" "$UNAUTH_PATH" 50 5 &
    PID_UNAUTH=$!

    wait "$PID_PORTAL" "$PID_SELECAO" "$PID_INGRESSO" "$PID_UNAUTH" 2>/dev/null || true
    log_ok "Tráfego gerado"
fi

# ── Aguardar pipeline convergir ───────────────────────────────────────────────
log "Aguardando ${WAIT_SECS}s para OTelCol → prometheusremotewrite → TSDB convergir..."
sleep "$WAIT_SECS"
log "Pipeline deve ter processado — iniciando validações PromQL"

# ── Helpers PromQL ────────────────────────────────────────────────────────────
prom_query() {
    # Retorna o JSON completo da query instant
    local query="$1"
    curl -sf \
        "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
        --get \
        --data-urlencode "query=${query}" \
        "${PROM_URL}/api/v1/query" \
        | jq -r '.'
}

prom_result_count() {
    # Conta o número de result items retornados
    local query="$1"
    prom_query "$query" | jq -r '.data.result | length'
}

prom_result_values() {
    # Retorna table: metric_labels → value
    local query="$1"
    prom_query "$query" \
        | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\"\(.value)\"") | join(", ")) → \(.value[1])"'
}

# ── Validação 1 — Existência das séries http_server_* ────────────────────────
log "Validação 1: existência de http_server_request_duration_seconds_count"

Q_EXISTENCE='count({__name__="http_server_request_duration_seconds_count", service_name=~"uniplus-api-.+"})'
EXISTENCE_COUNT=$(prom_result_count "$Q_EXISTENCE")
EXISTENCE_VAL=$(prom_query "$Q_EXISTENCE" | jq -r '.data.result[0].value[1] // "0"')

if [ "${EXISTENCE_VAL:-0}" != "0" ] && [[ "${EXISTENCE_VAL:-0}" =~ ^[0-9]+$ ]]; then
    log_ok "V1 PASS — ${EXISTENCE_VAL} série(s) com label service_name=uniplus-api-* encontrada(s)"
    V1_STATUS="PASS"
else
    log_err "V1 FAIL — nenhuma série http_server_request_duration_seconds_count com service_name=uniplus-api-*"
    log_err "       Verificar: (1) OTelCol rodando; (2) enableRemoteWriteReceiver=true; (3) apps com tráfego"
    V1_STATUS="FAIL"
fi

# Detalhe por service_name
V1_DETAIL=$(prom_query 'sum by (service_name) (http_server_request_duration_seconds_count{service_name=~"uniplus-api-.+"})' \
    | jq -r '.data.result[] | "  \(.metric.service_name): \(.value[1])"' 2>/dev/null || echo "  (sem dados)")

# ── Validação 2 — histogram_quantile p95 ─────────────────────────────────────
log "Validação 2: histogram_quantile(0.95) retorna valores não-NaN"

Q_QUANTILE='histogram_quantile(0.95, sum by (le, http_route, service_name) (rate(http_server_request_duration_seconds_bucket[5m])))'
V2_RESULTS=$(prom_query "$Q_QUANTILE" | jq -r '.data.result')
V2_COUNT=$(echo "$V2_RESULTS" | jq -r 'length')
V2_NAN_COUNT=$(echo "$V2_RESULTS" | jq -r '[.[] | select(.value[1] == "NaN")] | length')
V2_VALID_COUNT=$(( ${V2_COUNT:-0} - ${V2_NAN_COUNT:-0} ))

if [ "$V2_COUNT" -eq 0 ]; then
    log_warn "V2 WARN — histogram_quantile retornou 0 séries (dados podem ser muito recentes para rate[5m])"
    log_warn "         Reexecutar com WAIT_SECS=300 ou após 5 min de tráfego contínuo"
    V2_STATUS="WARN"
elif [ "$V2_VALID_COUNT" -gt 0 ]; then
    log_ok "V2 PASS — ${V2_VALID_COUNT}/${V2_COUNT} série(s) com p95 válido (não-NaN)"
    V2_STATUS="PASS"
else
    log_warn "V2 WARN — ${V2_COUNT} série(s) retornadas mas todas NaN (dados insuficientes para rate[5m])"
    V2_STATUS="WARN"
fi

V2_DETAIL=$(echo "$V2_RESULTS" \
    | jq -r '.[] | "  service_name=\(.metric.service_name // "<unset>") http_route=\(.metric.http_route // "<unset>") → p95=\(.value[1])s"' \
    2>/dev/null | head -20 || echo "  (sem dados)")

# ── Validação 3 — Cardinalidade ───────────────────────────────────────────────
log "Validação 3: cardinalidade de séries http_server_* < 10.000"

Q_CARDINALITY='{__name__=~"http_server_.*"}'
V3_RESULTS=$(prom_query "count($Q_CARDINALITY)" | jq -r '.data.result[0].value[1] // "0"')

if [ "${V3_RESULTS:-0}" = "0" ]; then
    log_warn "V3 WARN — nenhuma série http_server_* encontrada (dependente da V1)"
    V3_STATUS="WARN"
elif [[ "${V3_RESULTS:-0}" =~ ^[0-9]+$ ]] && [ "${V3_RESULTS}" -lt 10000 ]; then
    log_ok "V3 PASS — ${V3_RESULTS} série(s) http_server_* (< 10.000; cardinalidade saudável)"
    V3_STATUS="PASS"
else
    log_err "V3 FAIL — ${V3_RESULTS} série(s) http_server_* (≥ 10.000; investigar cardinalidade)"
    V3_STATUS="FAIL"
fi

V3_BREAKDOWN=$(prom_query 'count by (__name__)({__name__=~"http_server_.*"})' \
    | jq -r '.data.result[] | "  \(.metric.__name__): \(.value[1])"' \
    2>/dev/null || echo "  (sem dados)")

# ── Verificação http_route="<unset>" ─────────────────────────────────────────
log "Verificando endpoints com http_route=\"<unset>\""

Q_UNSET='sum by (service_name, http_status_code) (http_server_request_duration_seconds_count{http_route="<unset>"})'
V4_RESULTS=$(prom_query "$Q_UNSET")
V4_COUNT=$(echo "$V4_RESULTS" | jq -r '.data.result | length')

if [ "$V4_COUNT" -eq 0 ]; then
    log_ok "http_route=<unset>: nenhuma série — todos os endpoints têm route template"
    V4_STATUS="OK"
else
    log_warn "http_route=<unset>: ${V4_COUNT} série(s) detectada(s) — endpoints sem route template"
    log_warn "  Esperado para: requests 401/403 (auth rejeitou antes do routing)"
    V4_STATUS="WARN"
fi

V4_DETAIL=$(echo "$V4_RESULTS" \
    | jq -r '.data.result[] | "  service_name=\(.metric.service_name // "?") status=\(.metric.http_status_code // "?") count=\(.value[1])"' \
    2>/dev/null || echo "  (nenhuma)")

# ── Labels OTel resource — amostras ──────────────────────────────────────────
log "Coletando labels OTel resource presentes nas séries"

LABEL_SERVICE_NAMES=$(prom_query 'group by (service_name) ({__name__="http_server_request_duration_seconds_count"})' \
    | jq -r '.data.result[].metric.service_name // "?"' 2>/dev/null | sort | tr '\n' ' ')

LABEL_SERVICE_NS=$(prom_query 'group by (service_namespace) ({__name__="http_server_request_duration_seconds_count"})' \
    | jq -r '.data.result[].metric.service_namespace // "?"' 2>/dev/null | sort | tr '\n' ' ')

# ── Veredicto final ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Resultado do Smoke — Pipeline Metrics OTLP → Prometheus"
echo "════════════════════════════════════════════════════════"
printf "  V1 Existência séries:     %b\n" "${V1_STATUS}"
printf "  V2 histogram_quantile p95: %b\n" "${V2_STATUS}"
printf "  V3 Cardinalidade:          %b\n" "${V3_STATUS}"
printf "  V4 http_route=<unset>:     %b\n" "${V4_STATUS}"
echo "════════════════════════════════════════════════════════"

OVERALL="PASS"
for s in "$V1_STATUS" "$V2_STATUS" "$V3_STATUS"; do
    [ "$s" = "FAIL" ] && OVERALL="FAIL"
done

# ── Geração do documento markdown ────────────────────────────────────────────
RUN_DATE="$(date -u '+%Y-%m-%d %H:%M:%SZ')"
RUN_DATE_SHORT="$(date +%Y-%m-%d)"

cat > "$OUTPUT_FILE" <<MARKDOWN_EOF
# Smoke — Pipeline Metrics OTLP → Prometheus (standalone)

> **Issue:** [uniplus-infra#247](https://github.com/unifesspa-edu-br/uniplus-infra/issues/247)
> **Data:** ${RUN_DATE}
> **Operador:** executado via \`scripts/smoke-metrics-pipeline.sh\`

## Configuração do smoke

| Parâmetro | Valor |
|---|---|
| Prometheus | \`svc/${PROM_SVC}\` ns \`${PROM_NS}\` |
| API portal | \`${API_PORTAL_HOST}\` |
| API seleção | \`${API_SELECAO_HOST}\` |
| API ingresso | \`${API_INGRESSO_HOST}\` |
| Requests/API (health) | ${TRAFFIC_TOTAL} |
| Requests não-autenticadas | 50 |
| Espera pós-tráfego | ${WAIT_SECS}s |
| Tráfego gerado | $([ "$SKIP_TRAFFIC" = "true" ] && echo "não (SKIP_TRAFFIC=true)" || echo "sim") |

## Resultado: ${OVERALL}

| Validação | Status | Detalhe |
|---|---|---|
| V1 — Existência séries \`http_server_*\` | ${V1_STATUS} | ${EXISTENCE_VAL:-0} série(s) com service_name=uniplus-api-* |
| V2 — histogram_quantile(0.95) não-NaN | ${V2_STATUS} | ${V2_VALID_COUNT:-0}/${V2_COUNT:-0} série(s) válidas |
| V3 — Cardinalidade < 10.000 | ${V3_STATUS} | ${V3_RESULTS:-0} série(s) http_server_* total |
| V4 — http_route="<unset>" | ${V4_STATUS} | ${V4_COUNT:-0} série(s) detectada(s) |

---

## V1 — Existência de \`http_server_request_duration_seconds_count\`

**Query:**
\`\`\`promql
count({__name__="http_server_request_duration_seconds_count", service_name=~"uniplus-api-.+"})
\`\`\`

**Resultado:** \`${EXISTENCE_VAL:-0}\` série(s)

**Por service_name:**
\`\`\`
${V1_DETAIL}
\`\`\`

---

## V2 — histogram_quantile p95

**Query:**
\`\`\`promql
histogram_quantile(0.95, sum by (le, http_route, service_name) (rate(http_server_request_duration_seconds_bucket[5m])))
\`\`\`

**Resultado (até 20 primeiras séries):**
\`\`\`
${V2_DETAIL}
\`\`\`

> **Nota:** status WARN indica dados insuficientes para rate[5m] — esperado se o smoke for
> executado logo após a primeira ingestão. Reexecutar com \`WAIT_SECS=300\` ou após 5 min de
> tráfego contínuo para resultado PASS garantido.

---

## V3 — Cardinalidade

**Query:**
\`\`\`promql
count by (__name__)({__name__=~"http_server_.*"})
\`\`\`

**Resultado:**
\`\`\`
${V3_BREAKDOWN}
\`\`\`

**Total:** ${V3_RESULTS:-0} série(s) (limite: 10.000)

---

## V4 — Endpoints com \`http_route="<unset>"\`

**Query:**
\`\`\`promql
sum by (service_name, http_status_code) (http_server_request_duration_seconds_count{http_route="<unset>"})
\`\`\`

**Resultado:**
\`\`\`
${V4_DETAIL}
\`\`\`

> Séries com \`http_route="<unset>"\` e \`http_status_code="401"\` são **esperadas**: o middleware
> de autenticação do ASP.NET Core rejeita a request antes do routing, então o OTel SDK não
> consegue popular o route template. Não requer correção. Séries com status 2xx ou 4xx/5xx
> não-auth indicam endpoints sem \`[Route]\` template — investigar se aparecerem.

---

## Labels OTel resource presentes

| Label | Valores observados |
|---|---|
| \`service_name\` | \`${LABEL_SERVICE_NAMES:-"(nenhum)"}\` |
| \`service_namespace\` | \`${LABEL_SERVICE_NS:-"(nenhum)"}\` |

> Labels \`service_version\`, \`deployment_environment\`, \`dc\` e \`cluster\` são adicionados pelo
> OTel Collector via processor \`resource\` (ver \`platform/observability/otelcol/values.yaml\`).

---

## Comandos de verificação manual

\`\`\`bash
# Port-forward local (executar em terminal separado):
kubectl port-forward -n ${PROM_NS} svc/${PROM_SVC} 19090:9090

# Inspecionar series diretamente:
curl -s 'localhost:19090/api/v1/label/service_name/values' | jq .

# Feature #242 acceptance criteria — count > 0:
curl -sG 'localhost:19090/api/v1/query' \\
  --data-urlencode 'query=count(http_server_request_duration_seconds_count{service_namespace="uniplus"}) > 0' | jq .

# Feature #242 acceptance criteria — histogram_quantile p95 por service:
curl -sG 'localhost:19090/api/v1/query' \\
  --data-urlencode 'query=histogram_quantile(0.95, sum by (le, http_route, service_name) (rate(http_server_request_duration_seconds_bucket[5m])))' | jq .
\`\`\`

---

*Gerado por \`scripts/smoke-metrics-pipeline.sh\` em ${RUN_DATE}.*
MARKDOWN_EOF

log "Documento salvo em: ${OUTPUT_FILE}"

# Retorno para CI / chamador
if [ "$OVERALL" = "FAIL" ]; then
    fail "Smoke FAIL — verificar V1 e V3 acima"
fi

log_ok "Smoke ${OVERALL} — pipeline metrics OTLP → Prometheus validado"
