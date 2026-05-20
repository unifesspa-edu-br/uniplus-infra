#!/usr/bin/env bash
# shellcheck shell=bash
#
# Smoke E2E dos dashboards Grafana uniplus-web (#307) e uniplus-traefik (#308).
#
# O script:
#   1. Gera tráfego controlado nos frontends e APIs Uni+ via HTTPS público.
#   2. Aguarda o pipeline OTelCol → Loki/Prometheus convergir.
#   3. Valida queries Loki para o dashboard uniplus-web (logs nginx filtráveis).
#   4. Valida queries Loki para o dashboard uniplus-traefik (access log JSON).
#   5. Valida queries Prometheus para disponibilidade de pods (ambos dashboards).
#   6. Verifica via Grafana API que os dois dashboards existem e são acessíveis.
#   7. Persiste saída em docs/validacao/dashboards-<data>.md
#
# Uso:
#   ./scripts/smoke-dashboards.sh
#   SKIP_TRAFFIC=true ./scripts/smoke-dashboards.sh
#   SSH_HOST=ubuntu@137.131.131.6 ./scripts/smoke-dashboards.sh
#
# Variáveis de ambiente:
#   SSH_HOST           Host SSH com acesso ao cluster (default: ubuntu@137.131.131.6)
#   SSH_KEY            Chave SSH (default: ~/.ssh/id_ed25519)
#   GRAFANA_URL        URL pública do Grafana (default: https://standalone.portaluni.com.br/grafana)
#   GRAFANA_USER       Usuário Grafana (default: admin)
#   GRAFANA_PASS       Senha Grafana (default: vem do Secret K8s se não setada)
#   BASE_DOMAIN        Domínio base do cluster (default: standalone.portaluni.com.br)
#   WAIT_SECS          Segundos de espera pós-tráfego (default: 20)
#   SKIP_TRAFFIC       Se "true", pula geração de tráfego (default: false)
#   SKIP_TLS_VERIFY    Se "true", passa --insecure ao curl (default: false)
#   LOKI_NS            Namespace do Loki (default: observability-loki)
#   LOKI_SVC           Service do Loki (default: platform-observability-loki-uniplus-standalone-loki)
#   PROM_NS            Namespace do Prometheus (default: observability-prometheus)
#   PROM_SVC           Service do Prometheus (default: platform-observability-pro-prometheus)
#
# Pré-requisitos:
#   - curl, jq
#   - SSH configurado para SSH_HOST (sem senha ou chave em SSH_KEY)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuração ──────────────────────────────────────────────────────────────
SSH_HOST="${SSH_HOST:-ubuntu@137.131.131.6}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
BASE_DOMAIN="${BASE_DOMAIN:-standalone.portaluni.com.br}"
GRAFANA_URL="${GRAFANA_URL:-https://${BASE_DOMAIN}/grafana}"
GRAFANA_USER="${GRAFANA_USER:-admin}"

LOKI_NS="${LOKI_NS:-observability-loki}"
LOKI_SVC="${LOKI_SVC:-platform-observability-loki-uniplus-standalone}"
PROM_NS="${PROM_NS:-observability-prometheus}"
PROM_SVC="${PROM_SVC:-platform-observability-pro-prometheus}"

WAIT_SECS="${WAIT_SECS:-20}"
SKIP_TRAFFIC="${SKIP_TRAFFIC:-false}"

CURL_EXTRA_FLAGS=()
if [ "${SKIP_TLS_VERIFY:-false}" = "true" ]; then
    CURL_EXTRA_FLAGS=("--insecure")
fi

SSH_CMD=(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o BatchMode=yes "$SSH_HOST")

VALIDACAO_DIR="${REPO_ROOT}/docs/validacao"
OUTPUT_FILE="${VALIDACAO_DIR}/dashboards-$(date +%Y-%m-%d).md"

# ── Logging ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()     { printf '%s [smoke-dashboards] %s\n'     "$(date -u +%H:%M:%SZ)" "$1" >&2; }
log_ok()  { printf "%b[ OK ]%b %s\n"  "$GREEN"  "$NC" "$1" >&2; }
log_err() { printf "%b[FAIL]%b %s\n"  "$RED"    "$NC" "$1" >&2; }
log_warn(){ printf "%b[WARN]%b %s\n"  "$YELLOW" "$NC" "$1" >&2; }
fail()    { log_err "$1"; exit 1; }

# ── Pré-requisitos ────────────────────────────────────────────────────────────
log "Verificando pré-requisitos..."
command -v curl >/dev/null 2>&1 || fail "curl não encontrado"
command -v jq   >/dev/null 2>&1 || fail "jq não encontrado"

mkdir -p "$VALIDACAO_DIR"

# ── Credenciais Grafana ───────────────────────────────────────────────────────
# Se GRAFANA_PASS não está setado, tentar ler do Secret K8s via SSH.
if [ -z "${GRAFANA_PASS:-}" ]; then
    log "GRAFANA_PASS não definido — tentando ler do Secret K8s via SSH..."
    GRAFANA_PASS="$("${SSH_CMD[@]}" "kubectl get secret -n observability-grafana \$(kubectl get secret -n observability-grafana -o name | grep grafana | head -1) -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo ''")"
    if [ -z "$GRAFANA_PASS" ]; then
        log_warn "Não foi possível recuperar GRAFANA_PASS do Secret — tentando 'admin'"
        GRAFANA_PASS="admin"
    else
        log_ok "GRAFANA_PASS recuperado do Secret K8s"
    fi
fi

# ── Geração de tráfego ────────────────────────────────────────────────────────
if [ "$SKIP_TRAFFIC" = "true" ]; then
    log_warn "SKIP_TRAFFIC=true — pulando geração de tráfego"
else
    log "Gerando tráfego nos frontends e APIs..."

    TRAFFIC_PIDS=()

    # Frontends — 10 req × 3 apps (200 + 404 para testar detecção de erros)
    for app in selecao ingresso portal; do
        BASE="https://${app}.${BASE_DOMAIN}"
        for _ in $(seq 1 10); do
            curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
                -o /dev/null "$BASE/" 2>/dev/null &
            TRAFFIC_PIDS+=($!)
        done
        # Gerar alguns 404 (assets inexistentes)
        for _ in $(seq 1 3); do
            curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
                -o /dev/null "${BASE}/assets/smoke-test-$(date +%s).js" 2>/dev/null &
            TRAFFIC_PIDS+=($!)
        done
    done

    # APIs — health + 401 para exercitar Traefik routing
    for api in api-selecao api-ingresso; do
        BASE="https://${api}.${BASE_DOMAIN}"
        for _ in $(seq 1 5); do
            curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
                -o /dev/null "${BASE}/health" 2>/dev/null &
            TRAFFIC_PIDS+=($!)
            # Request não-autenticada — espera 401 (exercita Traefik route)
            curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
                -o /dev/null "${BASE}/api/editais" 2>/dev/null &
            TRAFFIC_PIDS+=($!)
        done
    done

    wait "${TRAFFIC_PIDS[@]}" 2>/dev/null || true
    log_ok "Tráfego gerado — aguardando ${WAIT_SECS}s para OTelCol batch + Loki flush..."
    sleep "$WAIT_SECS"
fi

# ── Helper: URL-encode string (local) ────────────────────────────────────────
urlencode() {
    # Codifica localmente antes de passar para o SSH (evita hell de quoting aninhado)
    python3 -c "import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1]))" "$1" 2>/dev/null || \
        printf '%s' "$1" | jq -sRr @uri 2>/dev/null || \
        printf '%s' "$1"
}

# ── Helper: query Loki via ClusterIP no SSH host ──────────────────────────────
loki_query_range() {
    # $1 = LogQL query, $2 = window (ex: "5m"), $3 = limit (default 10)
    local query="$1"
    local window="${2:-5m}"
    local limit="${3:-10}"
    local encoded_query
    encoded_query="$(urlencode "$query")"
    local secs="${window%m}"
    local start_ns
    start_ns=$(python3 -c "import time; print(int((time.time()-${secs}*60)*1e9))" 2>/dev/null || echo "0")
    local end_ns
    end_ns=$(python3 -c "import time; print(int(time.time()*1e9))" 2>/dev/null || echo "0")

    # Resolve Loki ClusterIP se ainda não foi resolvido
    if [ -z "${_LOKI_IP:-}" ]; then
        _LOKI_IP="$("${SSH_CMD[@]}" "kubectl get svc -n ${LOKI_NS} ${LOKI_SVC} -o jsonpath='{.spec.clusterIP}' 2>/dev/null" 2>/dev/null || echo "")"
    fi
    [ -z "$_LOKI_IP" ] && { echo '{"data":{"result":[]}}'; return; }

    local url="http://${_LOKI_IP}:3100/loki/api/v1/query_range?query=${encoded_query}&start=${start_ns}&end=${end_ns}&limit=${limit}"
    "${SSH_CMD[@]}" "curl -sf '${url}'" 2>/dev/null | jq -r '.' 2>/dev/null || echo '{"data":{"result":[]}}'
}

loki_count_results() {
    local query="$1"
    loki_query_range "$query" "5m" "1" | jq -r '.data.result | length' 2>/dev/null || echo "0"
}

loki_total_entries() {
    # Conta total de log entries (streams × values) retornados
    local query="$1"
    loki_query_range "$query" "5m" "100" | jq -r '[.data.result[].values | length] | add // 0' 2>/dev/null || echo "0"
}

# ── Helper: query Prometheus via ClusterIP no SSH host ───────────────────────
prom_query() {
    local query="$1"
    local encoded_query
    encoded_query="$(urlencode "$query")"

    if [ -z "${_PROM_IP:-}" ]; then
        _PROM_IP="$("${SSH_CMD[@]}" "kubectl get svc -n ${PROM_NS} ${PROM_SVC} -o jsonpath='{.spec.clusterIP}' 2>/dev/null" 2>/dev/null || echo "")"
    fi
    [ -z "$_PROM_IP" ] && { echo '{"data":{"result":[]}}'; return; }

    local url="http://${_PROM_IP}:9090/api/v1/query?query=${encoded_query}"
    "${SSH_CMD[@]}" "curl -sf '${url}'" 2>/dev/null | jq -r '.' 2>/dev/null || echo '{"data":{"result":[]}}'
}

prom_result_value() {
    local query="$1"
    prom_query "$query" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "0"
}

# ── Validação W1 — Logs nginx dos frontends em Loki ──────────────────────────
log "W1: verificando logs nginx dos frontends no Loki..."

LOKI_WEB_QUERY='{k8s_namespace_name="uniplus",k8s_deployment_name=~".*-uniplus-web-.*"}'
W1_STREAMS=$(loki_count_results "$LOKI_WEB_QUERY")
W1_ENTRIES=$(loki_total_entries "$LOKI_WEB_QUERY")

if [ "${W1_STREAMS:-0}" -gt 0 ] && [ "${W1_ENTRIES:-0}" -gt 0 ]; then
    log_ok "W1 PASS — ${W1_STREAMS} stream(s) / ${W1_ENTRIES} entradas (últimos 5min)"
    W1_STATUS="PASS"
else
    log_err "W1 FAIL — nenhum log nginx no Loki para k8s_deployment_name=~'.*-uniplus-web-.*'"
    log_err "        Verificar: (1) frontends rodando; (2) OTelCol filelog ativo; (3) Loki saudável"
    W1_STATUS="FAIL"
fi

# ── Validação W2 — Filtro de erros HTTP nos logs nginx ───────────────────────
log "W2: verificando detecção de erros HTTP 4xx/5xx nos logs nginx..."

LOKI_WEB_ERR='{k8s_namespace_name="uniplus",k8s_deployment_name=~".*-uniplus-web-.*"} |~ `" [45][0-9]{2} `'
W2_ENTRIES=$(loki_total_entries "$LOKI_WEB_ERR")

if [ "${W2_ENTRIES:-0}" -gt 0 ]; then
    log_ok "W2 PASS — ${W2_ENTRIES} entradas com status 4xx/5xx detectadas via regex"
    W2_STATUS="PASS"
else
    log_warn "W2 WARN — nenhum erro HTTP detectado (pode ser normal se sem 4xx/5xx recentes)"
    W2_STATUS="WARN"
fi

# ── Validação W3 — Pod availability dos frontends no Prometheus ───────────────
log "W3: verificando disponibilidade dos pods frontend no Prometheus..."

PROM_WEB='kube_deployment_status_replicas_available{namespace="uniplus",deployment=~".*-uniplus-web-.*"}'
W3_RESULT=$(prom_query "$PROM_WEB")
W3_COUNT=$(echo "$W3_RESULT" | jq -r '.data.result | length' 2>/dev/null || echo "0")
W3_ZERO=$(echo "$W3_RESULT" | jq -r '[.data.result[] | select(.value[1] == "0")] | length' 2>/dev/null || echo "0")
W3_DETAIL=$(echo "$W3_RESULT" | jq -r '.data.result[] | "  \(.metric.deployment): \(.value[1]) replica(s)"' 2>/dev/null || echo "  (sem dados)")

if [ "${W3_COUNT:-0}" -gt 0 ] && [ "${W3_ZERO:-0}" -eq 0 ]; then
    log_ok "W3 PASS — ${W3_COUNT} deployment(s) com réplicas disponíveis"
    W3_STATUS="PASS"
elif [ "${W3_COUNT:-0}" -gt 0 ]; then
    log_err "W3 FAIL — ${W3_ZERO}/${W3_COUNT} deployment(s) com 0 réplicas"
    W3_STATUS="FAIL"
else
    log_err "W3 FAIL — nenhuma métrica kube_deployment_status_replicas_available para frontends"
    W3_STATUS="FAIL"
fi

# ── Validação T1 — Access log Traefik no Loki ────────────────────────────────
log "T1: verificando access log Traefik no Loki..."

LOKI_TRAEFIK='{service_name=~"platform-traefik-.*"}'
T1_STREAMS=$(loki_count_results "$LOKI_TRAEFIK")
T1_ENTRIES=$(loki_total_entries "$LOKI_TRAEFIK")

if [ "${T1_STREAMS:-0}" -gt 0 ] && [ "${T1_ENTRIES:-0}" -gt 0 ]; then
    log_ok "T1 PASS — ${T1_STREAMS} stream(s) / ${T1_ENTRIES} entradas (últimos 5min)"
    T1_STATUS="PASS"
else
    log_err "T1 FAIL — nenhum log Traefik no Loki para service_name=~'platform-traefik-.*'"
    T1_STATUS="FAIL"
fi

# ── Validação T2 — Parse JSON do access log (DownstreamStatus) ───────────────
log "T2: verificando parse JSON do access log Traefik..."

LOKI_TRAEFIK_JSON='{service_name=~"platform-traefik-.*"} | json | DownstreamStatus >= 100'
T2_ENTRIES=$(loki_total_entries "$LOKI_TRAEFIK_JSON")

if [ "${T2_ENTRIES:-0}" -gt 0 ]; then
    log_ok "T2 PASS — ${T2_ENTRIES} entradas parseadas com | json | DownstreamStatus >= 100"
    T2_STATUS="PASS"
else
    log_err "T2 FAIL — parse JSON do access log Traefik falhou ou sem dados"
    log_err "        Verificar: (1) formato do access log (deve ser JSON); (2) field DownstreamStatus"
    T2_STATUS="FAIL"
fi

# ── Validação T3 — 4xx detectados nos logs Traefik ───────────────────────────
log "T3: verificando detecção de 4xx no access log Traefik..."

LOKI_TRAEFIK_4XX='{service_name=~"platform-traefik-.*"} | json | DownstreamStatus >= 400 | DownstreamStatus < 500'
T3_ENTRIES=$(loki_total_entries "$LOKI_TRAEFIK_4XX")

if [ "${T3_ENTRIES:-0}" -gt 0 ]; then
    log_ok "T3 PASS — ${T3_ENTRIES} entradas com DownstreamStatus 4xx detectadas"
    T3_STATUS="PASS"
else
    log_warn "T3 WARN — nenhum 4xx detectado (pode ser normal se sem clientes com erro recente)"
    T3_STATUS="WARN"
fi

# ── Validação T4 — Pod availability Traefik no Prometheus ────────────────────
log "T4: verificando disponibilidade do pod Traefik no Prometheus..."

PROM_TRAEFIK='kube_deployment_status_replicas_available{namespace="traefik",deployment=~"platform-traefik-.*"}'
T4_RESULT=$(prom_query "$PROM_TRAEFIK")
T4_COUNT=$(echo "$T4_RESULT" | jq -r '.data.result | length' 2>/dev/null || echo "0")
T4_REPLICAS=$(echo "$T4_RESULT" | jq -r '.data.result[0].value[1] // "0"' 2>/dev/null || echo "0")
T4_DETAIL=$(echo "$T4_RESULT" | jq -r '.data.result[] | "  \(.metric.deployment): \(.value[1]) replica(s)"' 2>/dev/null || echo "  (sem dados)")

if [ "${T4_COUNT:-0}" -gt 0 ] && [ "${T4_REPLICAS:-0}" != "0" ]; then
    log_ok "T4 PASS — Traefik com ${T4_REPLICAS} réplica(s) disponível(is)"
    T4_STATUS="PASS"
elif [ "${T4_COUNT:-0}" -gt 0 ]; then
    log_err "T4 FAIL — Traefik com 0 réplicas disponíveis"
    T4_STATUS="FAIL"
else
    log_err "T4 FAIL — nenhuma métrica kube_deployment_status_replicas_available para Traefik"
    T4_STATUS="FAIL"
fi

# ── Validação G1 — Dashboard uniplus-web existe no Grafana ───────────────────
log "G1: verificando dashboard uniplus-web no Grafana..."

G1_RESULT=$(curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    "${GRAFANA_URL}/api/dashboards/uid/uniplus-web" 2>/dev/null || echo '{}')
G1_TITLE=$(echo "$G1_RESULT" | jq -r '.dashboard.title // ""' 2>/dev/null || echo "")
G1_UID=$(echo "$G1_RESULT" | jq -r '.dashboard.uid // ""' 2>/dev/null || echo "")

if [ "$G1_UID" = "uniplus-web" ]; then
    log_ok "G1 PASS — dashboard '${G1_TITLE}' (uid=uniplus-web) encontrado no Grafana"
    G1_STATUS="PASS"
else
    log_err "G1 FAIL — dashboard uniplus-web não encontrado (ou credenciais incorretas)"
    G1_STATUS="FAIL"
fi

# ── Validação G2 — Dashboard uniplus-traefik existe no Grafana ───────────────
log "G2: verificando dashboard uniplus-traefik no Grafana..."

G2_RESULT=$(curl -sf "${CURL_EXTRA_FLAGS[@]+"${CURL_EXTRA_FLAGS[@]}"}" \
    -u "${GRAFANA_USER}:${GRAFANA_PASS}" \
    "${GRAFANA_URL}/api/dashboards/uid/uniplus-traefik" 2>/dev/null || echo '{}')
G2_TITLE=$(echo "$G2_RESULT" | jq -r '.dashboard.title // ""' 2>/dev/null || echo "")
G2_UID=$(echo "$G2_RESULT" | jq -r '.dashboard.uid // ""' 2>/dev/null || echo "")

if [ "$G2_UID" = "uniplus-traefik" ]; then
    log_ok "G2 PASS — dashboard '${G2_TITLE}' (uid=uniplus-traefik) encontrado no Grafana"
    G2_STATUS="PASS"
else
    log_err "G2 FAIL — dashboard uniplus-traefik não encontrado (ou credenciais incorretas)"
    G2_STATUS="FAIL"
fi

# ── Veredicto geral ───────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Smoke E2E — Dashboards Grafana (issues #307 e #308)"
echo "══════════════════════════════════════════════════════════════"
echo "  [uniplus-web #307]"
printf "    W1 Logs nginx Loki:           %s\n" "${W1_STATUS}"
printf "    W2 Detecção erros HTTP:        %s\n" "${W2_STATUS}"
printf "    W3 Pod availability Prometheus:%s\n" "${W3_STATUS}"
echo "  [uniplus-traefik #308]"
printf "    T1 Access log Traefik Loki:    %s\n" "${T1_STATUS}"
printf "    T2 Parse JSON DownstreamStatus:%s\n" "${T2_STATUS}"
printf "    T3 Detecção 4xx Traefik:       %s\n" "${T3_STATUS}"
printf "    T4 Pod availability Prometheus:%s\n" "${T4_STATUS}"
echo "  [Grafana API]"
printf "    G1 Dashboard uniplus-web:      %s\n" "${G1_STATUS}"
printf "    G2 Dashboard uniplus-traefik:  %s\n" "${G2_STATUS}"
echo "══════════════════════════════════════════════════════════════"

OVERALL="PASS"
for s in "$W1_STATUS" "$W3_STATUS" "$T1_STATUS" "$T2_STATUS" "$T4_STATUS" "$G1_STATUS" "$G2_STATUS"; do
    [ "$s" = "FAIL" ] && OVERALL="FAIL"
done

# ── Geração do documento markdown ────────────────────────────────────────────
RUN_DATE="$(date -u '+%Y-%m-%d %H:%M:%SZ')"

cat > "$OUTPUT_FILE" <<MARKDOWN_EOF
# Smoke E2E — Dashboards Grafana uniplus-web e uniplus-traefik

> **Issues:** [uniplus-infra#307](https://github.com/unifesspa-edu-br/uniplus-infra/issues/307), [uniplus-infra#308](https://github.com/unifesspa-edu-br/uniplus-infra/issues/308)
> **Data:** ${RUN_DATE}
> **Operador:** executado via \`scripts/smoke-dashboards.sh\`

## Configuração do smoke

| Parâmetro | Valor |
|---|---|
| Cluster SSH | \`${SSH_HOST}\` |
| Grafana | \`${GRAFANA_URL}\` |
| Loki | svc/\`${LOKI_SVC}\` ns \`${LOKI_NS}\` |
| Prometheus | svc/\`${PROM_SVC}\` ns \`${PROM_NS}\` |
| Tráfego gerado | $([ "$SKIP_TRAFFIC" = "true" ] && echo "não (SKIP_TRAFFIC=true)" || echo "sim") |
| Espera pós-tráfego | ${WAIT_SECS}s |

## Resultado: ${OVERALL}

| Validação | Status | Detalhe |
|---|---|---|
| W1 — Logs nginx em Loki | ${W1_STATUS} | ${W1_STREAMS} stream(s) / ${W1_ENTRIES} entradas |
| W2 — Detecção erros 4xx/5xx nginx | ${W2_STATUS} | ${W2_ENTRIES} entradas |
| W3 — Pod availability frontends | ${W3_STATUS} | ${W3_COUNT} deployment(s) |
| T1 — Access log Traefik em Loki | ${T1_STATUS} | ${T1_STREAMS} stream(s) / ${T1_ENTRIES} entradas |
| T2 — Parse JSON DownstreamStatus | ${T2_STATUS} | ${T2_ENTRIES} entradas parseadas |
| T3 — 4xx Traefik detectados | ${T3_STATUS} | ${T3_ENTRIES} entradas |
| T4 — Pod availability Traefik | ${T4_STATUS} | ${T4_REPLICAS} réplica(s) disponível(is) |
| G1 — Dashboard uniplus-web Grafana | ${G1_STATUS} | uid=uniplus-web, title="${G1_TITLE}" |
| G2 — Dashboard uniplus-traefik Grafana | ${G2_STATUS} | uid=uniplus-traefik, title="${G2_TITLE}" |

---

## Dashboard uniplus-web (#307)

### W1 — Logs nginx no Loki

**Query LogQL:**
\`\`\`logql
{k8s_namespace_name="uniplus",k8s_deployment_name=~".*-uniplus-web-.*"}
\`\`\`

**Resultado (últimos 5min):** ${W1_STREAMS} stream(s) / ${W1_ENTRIES} entradas

> Streams correspondem a cada deployment web (selecao/ingresso/portal × pods).
> Logs são nginx combined format (text); detected_level sempre "unknown".

### W2 — Detecção erros HTTP

**Query LogQL:**
\`\`\`logql
{k8s_namespace_name="uniplus",k8s_deployment_name=~".*-uniplus-web-.*"} |~ \`" [45][0-9]{2} \`
\`\`\`

**Resultado:** ${W2_ENTRIES} entradas com 4xx/5xx detectadas

> Regex filtra sobre o corpo do log nginx: \`"GET /path HTTP/1.1" 404 ...\`

### W3 — Pod availability frontends

**Query PromQL:**
\`\`\`promql
kube_deployment_status_replicas_available{namespace="uniplus",deployment=~".*-uniplus-web-.*"}
\`\`\`

**Resultado:**
\`\`\`
${W3_DETAIL}
\`\`\`

---

## Dashboard uniplus-traefik (#308)

### T1 — Access log Traefik em Loki

**Query LogQL:**
\`\`\`logql
{service_name=~"platform-traefik-.*"}
\`\`\`

**Resultado (últimos 5min):** ${T1_STREAMS} stream(s) / ${T1_ENTRIES} entradas

> Traefik emite JSON access log via stdout; OTelCol coleta via filelog e envia ao Loki.

### T2 — Parse JSON DownstreamStatus

**Query LogQL:**
\`\`\`logql
{service_name=~"platform-traefik-.*"} | json | DownstreamStatus >= 100
\`\`\`

**Resultado:** ${T2_ENTRIES} entradas parseadas com sucesso

> Valida que o campo \`DownstreamStatus\` (integer) existe no JSON e é parseável pelo Loki.

### T3 — Detecção de 4xx

**Query LogQL:**
\`\`\`logql
{service_name=~"platform-traefik-.*"} | json | DownstreamStatus >= 400 | DownstreamStatus < 500
\`\`\`

**Resultado:** ${T3_ENTRIES} entradas com 4xx

### T4 — Pod availability Traefik

**Query PromQL:**
\`\`\`promql
kube_deployment_status_replicas_available{namespace="traefik",deployment=~"platform-traefik-.*"}
\`\`\`

**Resultado:**
\`\`\`
${T4_DETAIL}
\`\`\`

---

## Grafana API

### G1 — Dashboard uniplus-web

| Campo | Valor |
|---|---|
| UID | \`uniplus-web\` |
| Título | ${G1_TITLE} |
| Status | ${G1_STATUS} |

### G2 — Dashboard uniplus-traefik

| Campo | Valor |
|---|---|
| UID | \`uniplus-traefik\` |
| Título | ${G2_TITLE} |
| Status | ${G2_STATUS} |

---

## Comandos de verificação manual

\`\`\`bash
# Query Loki direto (via kubectl exec):
ssh ${SSH_HOST} "kubectl exec -n ${LOKI_NS} svc/${LOKI_SVC} -- \\
  wget -qO- 'http://localhost:3100/loki/api/v1/query_range?query=%7Bk8s_namespace_name%3D%22uniplus%22%2Ck8s_deployment_name%3D~%22.*-uniplus-web-.*%22%7D&limit=5&start=0'"

# Verificar dashboard no Grafana:
curl -u admin:\$GRAFANA_PASS '${GRAFANA_URL}/api/dashboards/uid/uniplus-web' | jq .dashboard.title
curl -u admin:\$GRAFANA_PASS '${GRAFANA_URL}/api/dashboards/uid/uniplus-traefik' | jq .dashboard.title

# Acessar dashboards:
echo "Web:     ${GRAFANA_URL}/d/uniplus-web"
echo "Traefik: ${GRAFANA_URL}/d/uniplus-traefik"
\`\`\`

---

*Gerado por \`scripts/smoke-dashboards.sh\` em ${RUN_DATE}.*
MARKDOWN_EOF

log "Documento salvo em: ${OUTPUT_FILE}"

if [ "$OVERALL" = "FAIL" ]; then
    fail "Smoke FAIL — verificar validações acima"
fi

log_ok "Smoke ${OVERALL} — dashboards uniplus-web e uniplus-traefik validados"
