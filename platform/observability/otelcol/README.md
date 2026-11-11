# observability/otelcol

OpenTelemetry Collector, agente e gateway em um DaemonSet. Lê os logs dos contêineres do nó
(`filelog`), recebe OTLP das aplicações e enriquece com metadados do Kubernetes. Decisão:
[ADR-013](../../../docs/adrs/ADR-013-otel-collector-daemonset.md).

**Versão empacotada:** opentelemetry-collector 0.153.0 (collector 0.151.0), com alias `otelCollector`.

## Visão geral

- **Modo:** DaemonSet. **Imagem:** `otel/opentelemetry-collector-contrib` (a distribuição `k8s` não
  traz o exporter `prometheusremotewrite`).
- **Service:** `otelcol` no namespace `observability-otelcol`, portas 4317 (gRPC) e 4318 (HTTP). O
  nome vem de `fullnameOverride`, porque o gerado estoura 63 caracteres. Não há `hostPort`: o OTLP
  não tem autenticação e não pode ficar exposto no IP do nó.
- **Pipelines:** logs (`filelog` e OTLP) para o Loki; traces (OTLP) para o Tempo; métricas (OTLP)
  para o Prometheus por remote write.
- **Atributo `cluster`:** `uniplus`.

## Estrutura

```
platform/observability/otelcol/
├── Chart.yaml
├── values.yaml            # alternateConfig com a configuração completa
├── values.schema.json
└── templates/
    ├── _helpers.tpl
    └── networkpolicy.yaml # otelCollectorWrapper.networkPolicy
```

## Por que `alternateConfig` e não `config`

`null` em sub-chaves não remove receivers do merge padrão do chart
([helm/helm#12879](https://github.com/helm/helm/pull/12879)). `alternateConfig` substitui a
configuração por inteiro; o `filelog` e o `k8sattributes` entram pelos presets.

## O que o ambiente define

Os endpoints dos backends vêm de variáveis de ambiente, porque o `alternateConfig` não enxerga os
values do wrapper. Todas as três precisam ser passadas, pois a lista não faz merge:

```yaml
otelCollector:
  extraEnvs:
    - name: LOKI_OTLP_ENDPOINT
      value: http://platform-observability-loki.observability-loki.svc.cluster.local:3100/otlp
    - name: TEMPO_OTLP_ENDPOINT
      value: http://platform-observability-tempo.observability-tempo.svc.cluster.local:4318
    - name: PROMETHEUS_REMOTE_WRITE_ENDPOINT
      value: http://platform-observability-pro-prometheus.observability-prometheus.svc.cluster.local:9090/api/v1/write
otelCollectorWrapper:
  networkPolicy:
    enabled: true
    kubeApiCidrs: [<IP do host do cluster>/32]   # obrigatório com a política ligada
```

`ingressNamespaces` traz `uniplus`, `geo`, `traefik` e `keycloak-replica`; um namespace novo que
envie OTLP entra nessa lista.

## Como as aplicações enviam

`http://otelcol.observability-otelcol.svc.cluster.local:4317` (gRPC) ou `:4318` (HTTP). A
NetworkPolicy de cada aplicação precisa liberar o egress para `observability-otelcol`.

## Validação

```bash
helm dependency update platform/observability/otelcol
helm template platform-observability-otelcol platform/observability/otelcol \
  -f environments/uniplus-prd/values.yaml --namespace observability-otelcol
```

Nenhum contêiner do render declara `hostPort`.

## Referências

- [OpenTelemetry Collector](https://opentelemetry.io/docs/collector/)
- [Helm chart](https://github.com/open-telemetry/opentelemetry-helm-charts/tree/main/charts/opentelemetry-collector)
- [Endpoint OTLP do Loki](https://grafana.com/docs/loki/latest/send-data/otel/)
- [ADR-013](../../../docs/adrs/ADR-013-otel-collector-daemonset.md)
