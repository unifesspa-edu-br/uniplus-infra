# ADR-012 — Tempo single-binary com storage S3-MinIO em standalone

- **Status:** Accepted
- **Data:** 2026-05-10
- **Sub-issue:** [#29 task(observability): completar Helm chart wrapper para Tempo](https://github.com/unifesspa-edu-br/uniplus-infra/issues/29)
- **Refs:** ADR-008 (topologia standalone), ADR-011 (Loki SingleBinary — pattern análogo), [#3 — umbrella plataforma], [#30 — OTel Collector (próximo passo, emissor de traces)]

## Contexto

O backlog de observabilidade tem três sub-issues sequenciais — #28 Loki (logs, fechado em [PR #221]), **#29 Tempo (traces — este ADR)** e #30 OTel Collector. Antes desta entrega, `platform/observability/tempo/` continha apenas `README.md` placeholder; ApplicationSet `uniplus-platform` ficava `Unknown / Healthy` — sem qualquer pod de Tempo rodando.

O ambiente standalone roda em **single-cluster** com volumetria esperada baixa (POC + smoke das APIs), bucket MinIO `tempo-traces` já provisionado em PR #135 e credencial dedicada `tempo-svc` (policy escopada `tempo-rw`) custodiada em Vault `secret/standalone/minio/tempo` (criada em spike Fase 1 — 2026-05-10, ver ADR-011 para detalhes do pattern).

Este ADR fixa a topologia de Tempo em standalone seguindo o **mesmo pattern do Loki (ADR-011)** — chart wrapper sobre upstream em modo single-binary, storage S3, env-expansion para creds, NetworkPolicy escopada, ExternalSecret via ESO.

## Decisão

Para **standalone**:

1. **Chart upstream `grafana/tempo` 1.24.4 — single-binary mode** (1 réplica). Existem dois charts na org Grafana: `grafana/tempo` (single-binary, esse) e `grafana/tempo-distributed` (microservices). Single-binary é apropriado para baixa volumetria; distributed só faz sentido a partir de ~milhares de spans/segundo.
2. **Storage backend `s3`** apontando para MinIO local com:
   - bucket `tempo-traces`
   - credencial dedicada `tempo-svc` (policy `tempo-rw` escopada apenas a esse bucket)
   - `forcepathstyle: true` (MinIO exige path-style)
   - `insecure: true` (HTTP no tráfego intra-VPC)
3. **Receivers APENAS OTLP** (gRPC `:4317` + HTTP `:4318`). Jaeger e OpenCensus desligados — apps Uni+ usam OpenTelemetry SDK (.NET) que emite OTLP nativo, e o OTel Collector (#30) também emite OTLP. Sem necessidade de manter receivers legados expostos.
4. **Retention 72h (3 dias)** via `compactor.compaction.block_retention`. Alinhado com `observability.tempo.retention: 3d` documentado em `environments/standalone/values.yaml`.
5. **`-config.expand-env=true`** em `tempo.extraArgs` para interpolação `${TEMPO_S3_*}` na config a partir de env vars do Secret sintetizado pelo ESO.
6. **NetworkPolicy escopada**: ingress permitido apenas dos namespaces `observability-grafana` (consumidor de query) e `observability-otel-collector` (emissor de traces — futuro #30); egress permitido para MinIO + DNS K8s.
7. **Pattern de chave única** `uniplusExternalSecrets:` e `uniplusNetworkPolicy:` no top-level (mesma justificativa do ADR-011: evitar colisão com `networkPolicy:` upstream que gera regras próprias).
8. **Helper `uniplus-tempo.s3SecretName` retorna nome FIXO `tempo-s3-creds`** (sem release prefix) — mesma justificativa do Codex P2 resolvido no PR #221: `extraEnvFrom` consumido pelo subchart aceita apenas literal, então acoplar ao release name causa drift entre `ExternalSecret.target.name` e `secretRef.name` quando o AppSet renderiza com nome diferente.

Para **prod-{sp1, sp2}**: ADR separada quando #4 fechar e a política multi-DC for definida.

## Consequências

### Positivas

- ApplicationSet `platform-observability-tempo-uniplus-standalone` sai de `Unknown` para `Synced/Healthy`.
- Traces persistidos com retenção declarativa de 3 dias.
- Reuso do MinIO standalone — bucket já existente, custo zero.
- Receivers só OTLP simplifica auditoria de portas expostas.
- Tempo Query (UI Jaeger-like) **não habilitado** — UI fica no Grafana datasource (Tempo backend headless).

### Negativas / aceitas

- **1 réplica** = ponto único de falha durante restart de pod. Aceitável em POC; em prod multi-DC haverá tempo-distributed ou réplicas com leader election.
- **Sem metrics-generator** (geração de métricas a partir de traces) — economiza recursos; será habilitado quando o Prometheus consumidor estiver pronto.
- **Sem Tempo Query UI** — usuários acessam traces apenas via Grafana datasource. Trade-off OK pois Grafana já é o portal único de observabilidade.

### Riscos remanescentes

- **Tempo upstream chart 1.24.4** (app 2.9.0) é versão recente. Validamos via `helm template`; smoke pós-merge confirma startup. Fallback: `1.23.x` (mesma família app 2.x).
- **Retention 72h em standalone**: pode parecer curto em ciclo de incidente longo. Ajustável via override no environment quando smoke real definir window típica.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **Chart `grafana/tempo-distributed`** | Microservices (distributor, ingester, querier, query-frontend, compactor separados) — overhead operacional sem ganho em standalone single-cluster baixa volumetria. |
| **Receivers Jaeger + OpenCensus + Zipkin habilitados** | Mais surface exposta sem consumidor real (apps Uni+ emitem só OTLP). Aceitar push de outros formatos seria custo sem benefício até integração externa exigir. |
| **Storage local (PVC)** | Sem retention multi-DC, sem backup natural; custo de migração futura para S3 não justifica POC simplicidade. Já temos S3-MinIO disponível. |
| **Tempo Query UI ativada** | Duplica capacidade do Grafana datasource sem agregar valor; Grafana é o portal único de observabilidade. |
| **Bucket dedicado por DC** | Aplicará quando #12 (replicação MinIO multi-DC) entregar; standalone reutiliza `tempo-traces` que já existe. |

## Validação

- `helm lint platform/observability/tempo/` ✓
- `helm template -f environments/standalone/values.yaml` ✓
- `kubeconform -strict -summary -ignore-missing-schemas` ✓ (skip ExternalSecret CRD)
- Smoke pós-merge: pod `Running`, push de trace via OTLP/HTTP aceito, query via API HTTP devolve span, objeto aparece em `mc ls s/tempo-traces/`.

## Referências

- [Tempo chart docs](https://grafana.com/docs/tempo/latest/setup/helm-chart/)
- [Tempo storage config](https://grafana.com/docs/tempo/latest/configuration/#storage)
- [Tempo OTLP receiver](https://grafana.com/docs/tempo/latest/configuration/#receivers)
- ADR-011 — Loki SingleBinary (pattern análogo)
- ADR-008 — Topologia standalone monolocal
