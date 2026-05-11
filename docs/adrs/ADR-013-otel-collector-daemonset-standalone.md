# ADR-013 — OpenTelemetry Collector em DaemonSet único (agent + gateway) em standalone

- **Status:** Accepted
- **Data:** 2026-05-11
- **Sub-issue:** [#30 task(observability): completar Helm chart wrapper para OpenTelemetry Collector](https://github.com/unifesspa-edu-br/uniplus-infra/issues/30)
- **Refs:** ADR-011 (Loki), ADR-012 (Tempo), [#3 — umbrella plataforma]

## Contexto

Última peça do stack de observability lifecycle (após Loki em #28 / ADR-011 e Tempo em #29 / ADR-012). Antes desta entrega, `platform/observability/otel-collector/` continha apenas `README.md` placeholder; ApplicationSet `uniplus-platform` ficava `Unknown / Healthy` para esse componente.

Em padrão produção a recomendação OpenTelemetry é separar:

- **Agent (DaemonSet)**: 1 pod por nó, coleta logs locais via `filelog` receiver, expõe OTLP local pra apps no mesmo nó (low-latency).
- **Gateway (Deployment)**: 2+ pods em deployment, recebe OTLP dos agents, processa em batch maior, exporta para Loki/Tempo/Prometheus.

Em **standalone single-cluster single-node**, essa separação adiciona pods + complexidade de roteamento OTLP entre agent → gateway sem ganho operacional — é o mesmo nó.

## Decisão

Para **standalone**:

1. **DaemonSet único** que atua como agent E gateway. Em single-node é equivalente ao Deployment para fins de routing OTLP, mas **necessário em mode `daemonset`** para os presets `logsCollection` (filelog) e `kubernetesAttributes` (precisa de RBAC + volume mount no nó). Em prod, separar.
2. **Chart upstream `open-telemetry/opentelemetry-collector` 0.153.0 (app `0.151.0`)** com **alias `otelCollector`** no Chart.yaml. Único wrapper deste lote com alias — necessário porque `opentelemetry-collector` (com hífen) não é Go identifier válido para acesso direto a values; `otelCollector` é um alias curto.
3. **Imagem `otel/opentelemetry-collector-k8s`** (distribuição K8s — inclui contrib receivers/exporters: filelog, k8sattributes, otlphttp, etc.).
4. **Presets ativos**:
   - `logsCollection`: filelog receiver com hostPath em `/var/log/containers` + checkpoint storage em `/var/lib/otelcol`.
   - `kubernetesAttributes`: enriquece logs/traces com pod/namespace/node metadata; ClusterRole + Binding criados pelo preset.
5. **`alternateConfig` (não `config`)** para definir pipelines completas. O upstream tem [bug Helm conhecido (#12879)](https://github.com/helm/helm/pull/12879) onde `null` em sub-keys NÃO remove receivers/exporters do default merge — `alternateConfig` substitui a config inteira sem hash merge, dando controle autoritativo.
6. **Receivers**: APENAS OTLP gRPC (`:4317`) + OTLP HTTP (`:4318`). Jaeger e Zipkin desligados — apps Uni+ usam OpenTelemetry SDK (.NET) que emite OTLP nativo. (Mesma decisão do Tempo em ADR-012 — alinhamento entre componentes.)
7. **Exporters**:
   - `otlphttp/loki` — Loki 3.x suporta OTLP nativo no endpoint `/otlp/v1/logs`. O `lokiexporter` clássico foi **removido em otelcol-contrib 0.108+** (recomendação atual upstream é OTLP).
   - `otlphttp/tempo` — para Tempo via OTLP HTTP `:4318`.
   - `debug` — stdout, útil para troubleshooting (verbosity=basic).
8. **Pipelines**:
   - `logs`: `[otlp]` + filelog (preset) → `[memory_limiter, resource, batch]` + k8sattributes (preset) → `[otlphttp/loki, debug]`
   - `traces`: `[otlp]` → `[memory_limiter, resource, batch]` + k8sattributes → `[otlphttp/tempo, debug]`
   - **SEM `metrics`** — `kube-prometheus-stack` (ADR não-numerada, em uso) já scrape direto os apps via ServiceMonitor; pipeline aqui seria redundante.
9. **`resource` processor** injeta `cluster=standalone` e `dc=standalone` em todos os spans/logs — viabiliza filtragem por DC quando outros environments entrarem.
10. **NetworkPolicy escopada via `otelCollectorWrapper.networkPolicy`** (mesmo pattern de chave única do Loki/Tempo): ingress dos namespaces de apps (`uniplus`, `traefik`, `keycloak`) + intra-NS; egress para Loki, Tempo, DNS, kube-apiserver (k8sattributes precisa Watch em pods).
11. **Service ClusterIP ativado** (`service.enabled: true`) — chart upstream desativa Service por default em mode daemonset (presume hostPort). Em standalone queremos Service como fallback consistente para apps que não têm hostPort awareness.
12. **Sem ExternalSecret** — collector não consome credenciais externas (endpoints internos do cluster Loki+Tempo).
13. **Renomeação `otel-collector` → `otelcol`** (diretório, AppSet `component`, Chart name): release name `platform-observability-otel-collector-uniplus-standalone` exceedia 53 chars (limite do Helm); `otelcol` reduz para 49 chars.

Para **prod-{sp1, sp2}**: ADR separada quando #4 fechar, provavelmente com Agent (DaemonSet) + Gateway (Deployment) separados.

## Consequências

### Positivas

- ApplicationSet `platform-observability-otelcol-uniplus-standalone` sai de `Unknown` para `Synced/Healthy`.
- Logs de TODOS os pods do cluster passam a fluir para Loki via filelog (sem precisar de Promtail/Alloy separado).
- Apps emitindo OTLP via SDK (.NET OpenTelemetry) chegam ao collector local (latência mínima) e são roteados para Tempo (traces) e Loki (logs).
- k8sattributes enriquece automaticamente cada log/trace com metadata do pod (`k8s.namespace.name`, `k8s.pod.name`, `k8s.container.name`) — viabiliza filtros LogQL/TraceQL no Grafana.

### Negativas / aceitas

- **DaemonSet em single-node** = equivalente a Deployment 1-replica, mas overhead conceitual de "agent". Aceitável; necessário para presets.
- **`alternateConfig`** exige config completa (sem merge com defaults) — código mais verboso, mas autoritativo. Sem isso o bug do Helm impediria remoção de receivers indesejados.
- **`hostPort: 4317/4318`** ocupa as portas do nó (compartilhadas com qualquer DaemonSet). Em standalone single-node não há colisão; em prod com mais DaemonSets, monitorar.
- **Sem pipeline `metrics`** — apps que querem expor métricas continuam fazendo via Prometheus scrape direto. Se algum app só tiver OTLP metrics, precisará habilitar pipeline aqui.

### Riscos remanescentes

- **`otlphttp/loki` é endpoint OTLP** — Loki 3.x suporta nativo, mas requer config `loki.limits_config.allow_structured_metadata: true` (já default em Loki 3.6.x). Validar no smoke E2E.
- **OTel Collector upstream 0.153.0 (app 0.151.0)** é versão recente. Fallback: `0.150.x` (mesma família app 0.x).
- **Renomear pasta `otel-collector` → `otelcol`** rompe referências antigas — feito atomicamente neste PR (AppSet + values + ADR + README); ApplicationSet antigo `platform-observability-otel-collector-uniplus-standalone` será PRUNED automaticamente pelo Argo (não tem mais entry no AppSet).

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **Agent (DaemonSet) + Gateway (Deployment) separados** | Pattern produção; em standalone single-node, gera 2x pods sem ganho. Adiar pra prod ADR. |
| **`config` (com merge) em vez de `alternateConfig`** | Bug Helm conhecido — `null` não remove sub-keys. Receivers indesejados (jaeger/zipkin/prometheus interno) ficariam expostos no Service e nas pipelines. |
| **Promtail/Grafana Alloy separado para logs** | Adiciona componente. OTel Collector com `filelog` cobre o caso (Promtail está em soft-deprecation desde Grafana Labs anunciar Alloy em 2024). |
| **Receivers Jaeger/Zipkin/OpenCensus habilitados** | Apps Uni+ usam OTLP nativo; manter outros receivers só agrega surface sem consumidor. |
| **Pipeline `metrics` habilitada** | `kube-prometheus-stack` cobre. Adiar habilitação até apps terem métricas que NÃO sejam Prometheus-native. |
| **Exporter `lokiexporter` clássico** | Removido em otelcol-contrib 0.108+. `otlphttp/loki` é a recomendação atual upstream. |
| **Manter pasta `otel-collector` (nome longo)** | Release name `platform-observability-otel-collector-uniplus-standalone` excede 53 chars (limite Helm). Alternativas: trunc no AppSet (deixa nome cortado feio) ou conditional template (hack). Renomear para `otelcol` é a solução limpa. |

## Validação

- `helm lint platform/observability/otelcol/` ✓
- `helm template -f environments/standalone/values.yaml` ✓ (7 recursos: ServiceAccount, ConfigMap, ClusterRole+Binding, DaemonSet, Service, NetworkPolicy)
- `kubeconform -strict` ✓ (Valid 7/7)
- Smoke pós-merge: pod 1/1 Running, push log via OTLP HTTP aceito, log aparece no Loki, push trace aceito, trace aparece no Tempo. (Validação detalhada em PR.)

## Referências

- [OpenTelemetry Collector Helm chart](https://opentelemetry.io/docs/collector/installation/#helm-chart)
- [OpenTelemetry filelog receiver](https://opentelemetry.io/docs/kubernetes/collector/components/#filelog-receiver)
- [OpenTelemetry k8sattributes processor](https://opentelemetry.io/docs/kubernetes/collector/components/#kubernetes-attributes-processor)
- [Loki OTLP endpoint](https://grafana.com/docs/loki/latest/send-data/otel/)
- [Helm bug — null in subchart](https://github.com/helm/helm/pull/12879)
- ADR-011 — Loki SingleBinary
- ADR-012 — Tempo single-binary
