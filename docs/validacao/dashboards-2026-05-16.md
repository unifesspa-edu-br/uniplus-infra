# Smoke E2E — Dashboards Grafana uniplus-web e uniplus-traefik

> **Issues:** [uniplus-infra#307](https://github.com/unifesspa-edu-br/uniplus-infra/issues/307), [uniplus-infra#308](https://github.com/unifesspa-edu-br/uniplus-infra/issues/308)
> **Data:** 2026-05-16 19:52:11Z
> **Operador:** executado via `scripts/smoke-dashboards.sh`

## Configuração do smoke

| Parâmetro | Valor |
|---|---|
| Cluster SSH | `ubuntu@164.152.53.29` |
| Grafana | `https://standalone.portaluni.com.br/grafana` |
| Loki | svc/`platform-observability-loki-uniplus-standalone` ns `observability-loki` |
| Prometheus | svc/`platform-observability-pro-prometheus` ns `observability-prometheus` |
| Tráfego gerado | sim |
| Espera pós-tráfego | 20s |

## Resultado: PASS

| Validação | Status | Detalhe |
|---|---|---|
| W1 — Logs nginx em Loki | PASS | 1 stream(s) / 96 entradas |
| W2 — Detecção erros 4xx/5xx nginx | PASS | 18 entradas |
| W3 — Pod availability frontends | PASS | 3 deployment(s) |
| T1 — Access log Traefik em Loki | PASS | 1 stream(s) / 100 entradas |
| T2 — Parse JSON DownstreamStatus | PASS | 100 entradas parseadas |
| T3 — 4xx Traefik detectados | PASS | 58 entradas |
| T4 — Pod availability Traefik | PASS | 1 réplica(s) disponível(is) |
| G1 — Dashboard uniplus-web Grafana | PASS | uid=uniplus-web, title="Uni+ — Frontends Web" |
| G2 — Dashboard uniplus-traefik Grafana | PASS | uid=uniplus-traefik, title="Uni+ — Traefik (Ingress)" |

---

## Dashboard uniplus-web (#307)

### W1 — Logs nginx no Loki

**Query LogQL:**
```logql
{k8s_namespace_name="uniplus",k8s_deployment_name=~".*-uniplus-web-.*"}
```

**Resultado (últimos 5min):** 1 stream(s) / 96 entradas

> Streams correspondem a cada deployment web (selecao/ingresso/portal × pods).
> Logs são nginx combined format (text); detected_level sempre "unknown".

### W2 — Detecção erros HTTP

**Query LogQL:**
```logql
{k8s_namespace_name="uniplus",k8s_deployment_name=~".*-uniplus-web-.*"} |~ `" [45][0-9]{2} `
```

**Resultado:** 18 entradas com 4xx/5xx detectadas

> Regex filtra sobre o corpo do log nginx: `"GET /path HTTP/1.1" 404 ...`

### W3 — Pod availability frontends

**Query PromQL:**
```promql
kube_deployment_status_replicas_available{namespace="uniplus",deployment=~".*-uniplus-web-.*"}
```

**Resultado:**
```
  uniplus-web-uniplus-standalone-uniplus-web-portal: 1 replica(s)
  uniplus-web-uniplus-standalone-uniplus-web-selecao: 1 replica(s)
  uniplus-web-uniplus-standalone-uniplus-web-ingresso: 1 replica(s)
```

---

## Dashboard uniplus-traefik (#308)

### T1 — Access log Traefik em Loki

**Query LogQL:**
```logql
{service_name=~"platform-traefik-.*"}
```

**Resultado (últimos 5min):** 1 stream(s) / 100 entradas

> Traefik emite JSON access log via stdout; OTelCol coleta via filelog e envia ao Loki.

### T2 — Parse JSON DownstreamStatus

**Query LogQL:**
```logql
{service_name=~"platform-traefik-.*"} | json | DownstreamStatus >= 100
```

**Resultado:** 100 entradas parseadas com sucesso

> Valida que o campo `DownstreamStatus` (integer) existe no JSON e é parseável pelo Loki.

### T3 — Detecção de 4xx

**Query LogQL:**
```logql
{service_name=~"platform-traefik-.*"} | json | DownstreamStatus >= 400 | DownstreamStatus < 500
```

**Resultado:** 58 entradas com 4xx

### T4 — Pod availability Traefik

**Query PromQL:**
```promql
kube_deployment_status_replicas_available{namespace="traefik",deployment=~"platform-traefik-.*"}
```

**Resultado:**
```
  platform-traefik-uniplus-standalone: 1 replica(s)
```

---

## Grafana API

### G1 — Dashboard uniplus-web

| Campo | Valor |
|---|---|
| UID | `uniplus-web` |
| Título | Uni+ — Frontends Web |
| Status | PASS |

### G2 — Dashboard uniplus-traefik

| Campo | Valor |
|---|---|
| UID | `uniplus-traefik` |
| Título | Uni+ — Traefik (Ingress) |
| Status | PASS |

---

## Comandos de verificação manual

```bash
# Query Loki direto (via kubectl exec):
ssh ubuntu@164.152.53.29 "kubectl exec -n observability-loki svc/platform-observability-loki-uniplus-standalone -- \
  wget -qO- 'http://localhost:3100/loki/api/v1/query_range?query=%7Bk8s_namespace_name%3D%22uniplus%22%2Ck8s_deployment_name%3D~%22.*-uniplus-web-.*%22%7D&limit=5&start=0'"

# Verificar dashboard no Grafana:
curl -u admin:$GRAFANA_PASS 'https://standalone.portaluni.com.br/grafana/api/dashboards/uid/uniplus-web' | jq .dashboard.title
curl -u admin:$GRAFANA_PASS 'https://standalone.portaluni.com.br/grafana/api/dashboards/uid/uniplus-traefik' | jq .dashboard.title

# Acessar dashboards:
echo "Web:     https://standalone.portaluni.com.br/grafana/d/uniplus-web"
echo "Traefik: https://standalone.portaluni.com.br/grafana/d/uniplus-traefik"
```

---

*Gerado por `scripts/smoke-dashboards.sh` em 2026-05-16 19:52:11Z.*
