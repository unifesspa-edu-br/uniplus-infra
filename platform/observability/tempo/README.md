# observability/tempo

Backend de traces distribuídos para o Uni+ — chart wrapper sobre `grafana/tempo`
(single-binary mode) com receivers OTLP e storage S3-compatible
(MinIO em standalone).

> Decisão arquitetural: ver [ADR-012](../../../docs/adrs/ADR-012-tempo-singlebinary-s3-standalone.md).

## Visão geral

- **Modo**: single-binary (1 réplica) — apropriado para single-cluster com
  baixa volumetria (standalone POC, lab).
- **Storage**: S3-compatible. Em standalone aponta para MinIO local
  (`10.2.2.11:9000`, bucket `tempo-traces`, credencial dedicada `tempo-svc`
  custodiada em Vault `secret/standalone/minio/tempo`).
- **Receivers**: APENAS OTLP (gRPC `:4317` + HTTP `:4318`). Jaeger e
  OpenCensus desligados — apps Uni+ usam OpenTelemetry SDK que emite OTLP
  nativo.
- **Retention**: 72h (3 dias) em standalone, via `compactor.compaction.block_retention`.
- **Acesso**: Service ClusterIP — Grafana datasource consome
  `http://platform-observability-tempo-uniplus-standalone.observability-tempo.svc.cluster.local:3200`.

## Estrutura

```
platform/observability/tempo/
├── Chart.yaml                  # wrapper v2 + dep grafana/tempo 1.24.4
├── Chart.lock                  # lock do dep
├── values.yaml                 # defaults conservadores
├── values.schema.json          # validação dos campos críticos do wrapper
├── templates/
│   ├── _helpers.tpl            # nome do Secret S3, labels, selectors
│   ├── externalsecret.yaml     # gateado por tempoWrapper.externalSecrets.enabled
│   └── networkpolicy.yaml      # gateado por tempoWrapper.networkPolicy.enabled
└── charts/                     # gitignored — gerado por `helm dependency update`
    └── tempo-1.24.4.tgz
```

## Como o subchart é configurado

O subchart upstream `tempo` é injetado **sem alias**. Valores top-level
`tempo:` no `values.yaml` deste wrapper passam diretamente ao subchart.
Configurações próprias do wrapper Uni+ ficam em chave única **`tempoWrapper:`**
para isolar de outros wrappers (Loki/OTel) que dividem o mesmo environment
file.

O helper `_helpers.tpl` e os templates `externalsecret.yaml`/`networkpolicy.yaml`
só leem `.Values.tempoWrapper.{externalSecrets,networkPolicy}`.

## Quirks específicas

- `tempo.tempo.extraArgs` é **mapa** (não lista). Cada chave vira `-<key>={value}`
  no command-line do binário. Por isso `extraArgs.config.expand-env: "true"`
  renderiza como `-config.expand-env=true`. Lista geraria warning
  `cannot overwrite table with non table`.
- `forcepathstyle` (não `s3ForcePathStyle` como no Loki) — Tempo segue convenção
  snake_case do `oci-go-sdk` em parâmetros S3.
- `tempoQuery` (UI Jaeger-like) está **desligado** — UI fica no Grafana
  datasource, evitando duplicação de capacidade.

## Componentes desligados em standalone

- `tempoQuery` (UI Jaeger): Grafana datasource cobre.
- `metricsGenerator`: gera métricas a partir de traces; ligar quando o
  Prometheus consumidor estiver com remote-write configurado.
- `networkPolicy` upstream: substituído pelo wrapper escopado (`tempoWrapper`).

## Deploy

Via ArgoCD ApplicationSet `uniplus-platform` (em `argocd/applicationset.yaml`).
Sync automático para clusters com label `uniplus.io/managed: true`. Namespace
gerado pelo AppSet: `observability-tempo`.

## Validação

```bash
helm dependency update platform/observability/tempo
helm lint platform/observability/tempo
helm template platform-observability-tempo-uniplus-standalone \
  platform/observability/tempo \
  -f environments/standalone-compact/values.yaml \
  --namespace observability-tempo
```

## Smoke pós-sync (standalone)

```bash
ssh ubuntu@137.131.131.6
sudo k3s kubectl -n observability-tempo get pods           # 1/1 Running
sudo k3s kubectl -n observability-tempo port-forward \
  svc/platform-observability-tempo-uniplus-standalone 3200:3200 4318:4318 &

# Push de trace via OTLP/HTTP
TS=$(date +%s)
curl -X POST http://127.0.0.1:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"scopeSpans":[{"spans":[{
    "traceId":"5b8efff798038103d269b633813fc60c",
    "spanId":"eee19b7ec3c1b173","name":"smoke","kind":1,
    "startTimeUnixNano":"'${TS}000000000'",
    "endTimeUnixNano":"'$((TS+1))000000000'"
  }]}]}]}'

# Search API (espera 1-2 ciclos de flush antes de aparecer)
curl -s 'http://127.0.0.1:3200/api/search?tags=service.name=smoke' | jq
```

## Pendências (próximos PRs)

- **#30** — OTel Collector com OTLP receivers + exporter para este Tempo.
- **Datasource Tempo no Grafana** — habilitar via override em
  `environments/standalone-compact/values.yaml` no bloco `grafana.datasources` (PR
  separado).
- **MetricsGenerator + ServiceMonitor** — quando o Prometheus consumidor
  estiver pronto.

## Referências

- [Tempo chart docs](https://grafana.com/docs/tempo/latest/setup/helm-chart/)
- [Tempo configuration](https://grafana.com/docs/tempo/latest/configuration/)
- [Tempo OTLP receivers](https://grafana.com/docs/tempo/latest/configuration/#otlp)
- ADR-012 — decisão arquitetural completa
- ADR-011 — pattern análogo do Loki (referência)
- ADR-008 — topologia standalone monolocal
