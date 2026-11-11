# observability/prometheus

Prometheus, Prometheus Operator (CRDs de ServiceMonitor e PodMonitor), Alertmanager, node-exporter e
kube-state-metrics. Wrapper sobre
[kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack),
com o Grafana desligado (tem [chart próprio](../grafana/README.md)).

**Versão empacotada:** kube-prometheus-stack 84.5.0 (Operator 0.90.1, Prometheus 3.11).

## Visão geral

- **Release e Service:** em `platform-observability-prometheus`, o Prometheus é o Service
  `platform-observability-pro-prometheus` (porta 9090) em `observability-prometheus`: o subchart
  trunca o nome da release.
- **Retenção:** 7 dias e 8 GiB, em PVC de 10 GiB. O Alertmanager tem PVC de 2 GiB.
- **Remote write:** `enableRemoteWriteReceiver: true`; o OTel Collector envia as métricas das
  aplicações para `/api/v1/write`.
- **Alertmanager:** só o receiver `null`, que descarta os alertas, até haver canal de notificação.
- **Seleção:** aceita ServiceMonitors, PodMonitors e regras de qualquer namespace
  (`*SelectorNilUsesHelmValues: false`).

## Estrutura

```
platform/observability/prometheus/
├── Chart.yaml             # alias kubePrometheusStack
├── values.yaml
└── values.schema.json
```

## O que o ambiente define

```yaml
kubePrometheusStack:
  prometheus:
    prometheusSpec:
      externalLabels:
        cluster: <nome do ambiente>
      storageSpec:
        volumeClaimTemplate:
          spec:
            storageClassName: <StorageClass>
  alertmanager:
    alertmanagerSpec:
      storage:
        volumeClaimTemplate:
          spec:
            storageClassName: <StorageClass>
```

## Componentes do K3s

No K3s o controller-manager, o scheduler e o etcd rodam dentro do processo do K3s, sem endpoint
próprio, e o kube-proxy publica métricas só em `127.0.0.1`. Os quatro ServiceMonitors ficam
desligados para não gerar alertas `*Down` falsos.

## Rede

As NetworkPolicies são as do subchart (`kubePrometheusStack.prometheus.networkPolicy.enabled`);
o wrapper não as duplica.

## Validação

```bash
helm dependency update platform/observability/prometheus
helm template platform-observability-prometheus platform/observability/prometheus \
  -f environments/uniplus-prd/values.yaml --namespace observability-prometheus
```

## Referências

- [ADR-013](../../../docs/adrs/ADR-013-otel-collector-daemonset.md): fluxo das métricas das aplicações.
