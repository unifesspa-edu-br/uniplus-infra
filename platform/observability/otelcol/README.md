# observability/otelcol

OpenTelemetry Collector para Uni+ — agente unificado que:
- Coleta logs dos containers do nó (filelog receiver) → Loki
- Recebe traces OTLP dos apps → Tempo
- Enriquece com metadata K8s (k8sattributes processor)

> Decisão arquitetural: ver [ADR-013](../../../docs/adrs/ADR-013-otel-collector-daemonset-standalone.md).
>
> ⚠️ **Pasta renomeada de `otel-collector` para `otelcol`** — release name >53 chars (limite Helm) com nome longo. Diretório, AppSet `component` e Chart `name` foram atualizados em conjunto.

## Visão geral

- **Modo**: DaemonSet único (agent + gateway combinados em standalone). Em prod, separar.
- **Imagem**: `otel/opentelemetry-collector-k8s` (distribuição K8s — inclui contrib receivers/exporters).
- **Receivers**: APENAS OTLP gRPC (`:4317`) + HTTP (`:4318`). Jaeger/Zipkin desligados.
- **Exporters**: `otlphttp/loki` (Loki 3.x suporta OTLP nativo em `/otlp`), `otlphttp/tempo` (Tempo OTLP HTTP), `debug` (stdout).
- **Pipelines**: `logs` e `traces`. **SEM `metrics`** — Prometheus já scrape direto.
- **Resource attrs**: `cluster=standalone`, `dc=standalone` em todos spans/logs.

## Estrutura

```
platform/observability/otelcol/
├── Chart.yaml                  # wrapper v2 + dep open-telemetry/opentelemetry-collector 0.153.0 (alias otelCollector)
├── Chart.lock
├── values.yaml                 # defaults; usa alternateConfig para override completo
├── values.schema.json
├── templates/
│   ├── _helpers.tpl            # labels, selectors, fullname
│   └── networkpolicy.yaml      # gateado por otelCollectorWrapper.networkPolicy.enabled
└── charts/                     # gitignored — gerado por `helm dependency update`
    └── opentelemetry-collector-0.153.0.tgz
```

## Por que `alternateConfig` e não `config`

O chart upstream tem [bug Helm conhecido (#12879)](https://github.com/helm/helm/pull/12879) onde `null` em sub-keys NÃO remove receivers/exporters do default merge. `alternateConfig` substitui a config inteira, dando controle autoritativo. Trade-off: precisamos manter a config completa (sem benefício de merge), mas isso é o pattern correto pra evitar receivers indesejados expostos no Service.

## Por que `mode: daemonset` em standalone single-node

Os presets `logsCollection` (filelog receiver com hostPath em `/var/log/containers`) e `kubernetesAttributes` (precisa watch em pods do nó) **assumem mode daemonset**. Em standalone single-node, é equivalente a Deployment 1-replica para fins de routing OTLP entre apps e collector — mas o pattern segue o esperado pelos presets.

## Deploy

Via ArgoCD ApplicationSet `uniplus-platform`. Namespace gerado: `observability-otelcol`.

## Validação

```bash
helm dependency update platform/observability/otelcol
helm lint platform/observability/otelcol
helm template platform-observability-otelcol-uniplus-standalone \
  platform/observability/otelcol \
  -f environments/standalone/values.yaml \
  --namespace observability-otelcol
```

Esperado: 7 recursos (ServiceAccount, ConfigMap, ClusterRole, ClusterRoleBinding, DaemonSet, Service, NetworkPolicy).

## Smoke pós-sync (standalone)

```bash
ssh ubuntu@164.152.53.29
sudo k3s kubectl -n observability-otelcol get pods                 # 1/1 Running

# Push de log via OTLP HTTP (de outro pod no NS uniplus)
sudo k3s kubectl -n uniplus run otel-smoke --rm -i --restart=Never \
  --image=curlimages/curl -- \
  curl -X POST http://platform-observability-otelcol-uniplus-standalone.observability-otelcol:4318/v1/logs \
  -H 'Content-Type: application/json' -d '{...}'

# Validar log no Loki (datasource Grafana ou via port-forward Loki)
```

## Pendências (próximos PRs)

- **Datasources Loki + Tempo no Grafana** — habilitar via override em `environments/standalone/values.yaml` no bloco `grafana.datasources` (Fase 3 do plano).
- **MetricsGenerator + ServiceMonitor** — quando o Prometheus consumidor estiver pronto.
- **Pipeline `metrics`** — se algum app passar a expor métricas só via OTLP.

## Referências

- [OpenTelemetry Collector docs](https://opentelemetry.io/docs/collector/)
- [OpenTelemetry Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector)
- [Loki OTLP endpoint](https://grafana.com/docs/loki/latest/send-data/otel/)
- ADR-013 — decisão arquitetural completa
- ADR-011 + ADR-012 — Loki + Tempo (consumidores)
