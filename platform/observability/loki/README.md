# observability/loki

Agregação de logs estruturados para o Uni+ — chart wrapper sobre `grafana/loki`
em modo `SingleBinary` com storage S3-compatible (MinIO em standalone).

> Decisão arquitetural: ver [ADR-011](../../../docs/adrs/ADR-011-loki-singlebinary-s3-standalone.md).

## Visão geral

- **Modo**: `SingleBinary` (1 réplica, replication_factor 1) — apropriado para
  single-cluster com baixa volumetria (standalone POC, lab).
- **Storage**: S3-compatible. Em standalone aponta para MinIO local
  (`10.0.2.87:9000`, bucket `loki-chunks`, credencial dedicada `loki-svc`
  custodiada em Vault `secret/standalone/minio/loki`).
- **Schema**: TSDB v13 com índice `loki_index_` período 24h.
- **Retention**: 168h (7 dias) em standalone, ativada via compactor.
- **Acesso**: Service ClusterIP — Grafana datasource consome
  `http://platform-observability-loki-uniplus-standalone.observability-loki.svc.cluster.local:3100`.
  Sem gateway (nginx) e sem ingress externo.

## Estrutura

```
platform/observability/loki/
├── Chart.yaml                  # wrapper v2 + dep grafana/loki 7.0.0
├── Chart.lock                  # lock do dep
├── values.yaml                 # defaults conservadores
├── values.schema.json          # validação dos campos críticos do wrapper
├── templates/
│   ├── _helpers.tpl            # nome do Secret S3, labels, selectors
│   ├── externalsecret.yaml     # gateado por uniplusExternalSecrets.enabled
│   └── networkpolicy.yaml      # gateado por uniplusNetworkPolicy.enabled
└── charts/                     # gitignored — gerado por `helm dependency update`
    └── loki-7.0.0.tgz
```

## Como o subchart é configurado

O subchart upstream `loki` é injetado **sem alias**. Valores top-level `loki:`
no `values.yaml` deste wrapper passam diretamente ao subchart como
`.Values.x`. Configurações próprias do wrapper Uni+ (ExternalSecret,
NetworkPolicy) ficam em chave única **`lokiWrapper:`** para evitar:

1. Colisão com chaves homônimas do upstream (`networkPolicy:` upstream gera 5
   NPs próprias se ativado — desligamos).
2. Colisão com configs de OUTROS wrappers (Tempo/OTel) que dividem o mesmo
   environment file (`environments/<env>/values.yaml`). Chave prefixada por
   chart name garante isolamento absoluto.

O helper `_helpers.tpl` e os templates `externalsecret.yaml`/`networkpolicy.yaml`
só leem `.Values.lokiWrapper.{externalSecrets,networkPolicy}`.

## Componentes desligados em standalone

- `gateway` (nginx): Grafana acessa Service direto.
- `chunksCache` / `resultsCache` (memcached): overhead em single-node.
- `monitoring`, `lokiCanary`, `test`: gate por env quando consumidor
  Prometheus estiver pronto.
- `read` / `write` / `backend`: componentes do `SimpleScalable`, não usados
  em `SingleBinary`.
- `networkPolicy` upstream: substituído pelo wrapper escopado.

## Deploy

Via ArgoCD ApplicationSet `uniplus-platform` (em `argocd/applicationset.yaml`).
Sync automático para clusters com label `uniplus.io/managed: true`. Namespace
gerado pelo AppSet: `observability-loki`.

## Validação

```bash
helm dependency update platform/observability/loki
helm lint platform/observability/loki
helm template platform-observability-loki-uniplus-standalone \
  platform/observability/loki \
  -f environments/standalone/values.yaml \
  --namespace observability-loki
```

## Smoke pós-sync (standalone)

```bash
ssh ubuntu@164.152.53.29
sudo k3s kubectl -n observability-loki get pods           # 1/1 Running
sudo k3s kubectl -n observability-loki port-forward svc/platform-observability-loki-uniplus-standalone 3100:3100 &

# Push de log
curl -s -X POST http://127.0.0.1:3100/loki/api/v1/push \
  -H 'Content-Type: application/json' \
  -d '{"streams":[{"stream":{"app":"smoke"},"values":[["'$(date +%s%N)'","hello-loki"]]}]}'

# Query
curl -sG http://127.0.0.1:3100/loki/api/v1/query_range \
  --data-urlencode 'query={app="smoke"}' \
  --data-urlencode 'start='$(date -d '5 minutes ago' +%s)'000000000' | jq '.data.result'
```

## Pendências (próximos PRs)

- **#30** — OTel Collector com `filelog` receiver para popular Loki com logs
  do `containerd` automaticamente.
- **Datasource Loki no Grafana** — habilitar via override em
  `environments/standalone/values.yaml` no bloco `grafana.datasources` (PR
  separado da Fase 3 do plano de observability).
- **ServiceMonitor + alerts** — quando o Prometheus consumidor estiver pronto
  para scrape de métricas internas do Loki.
- **Per-DC bucket naming** (`loki-chunks-<dc>`) — quando #12 (replicação
  MinIO multi-DC) entregar.

## Referências

- [Loki Helm chart docs](https://grafana.com/docs/loki/latest/setup/install/helm/)
- [Loki TSDB schema](https://grafana.com/docs/loki/latest/operations/storage/tsdb/)
- ADR-011 — decisão arquitetural completa
- ADR-008 — topologia standalone monolocal
- ADR-007 — Vault HA storage unseal (consumido pelo ESO)
