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
- **Alertmanager:** receptores de e-mail por severidade (`critical` e `warning`) para o grupo de
  operação do Uni+, pelo relay SMTP institucional. O ExternalSecret `alertasEmail` monta o
  `alertmanager.yaml` inteiro a partir do segredo `smtp` do Vault (o mesmo da API) e o Operator o
  lê por `alertmanagerSpec.configSecret`. `Watchdog` e `InfoInhibitor` vão ao receptor `null`.
  Com `alertasEmail.enabled=false`, o chart cria no lugar um Secret de mesmo nome que descarta os
  alertas (receptor `null`). O namespace `observability-prometheus` precisa constar dos namespaces
  permitidos do store `plataforma`, inclusive nos values do repositório de implantação.
- **Alertas do Uni+:** `PrometheusRule` `uniplus-email-governanca` (envio de e-mail e governança de
  perfis da uniplus-api), com as regras em `rules/` e os testes em `tests/`.
- **Seleção:** aceita ServiceMonitors, PodMonitors e regras de qualquer namespace
  (`*SelectorNilUsesHelmValues: false`).

## Estrutura

```
platform/observability/prometheus/
├── Chart.yaml             # alias kubePrometheusStack
├── values.yaml
├── values.schema.json
├── rules/                 # regras de alerta em YAML puro (viram a PrometheusRule)
├── tests/                 # promtool test rules
└── templates/             # PrometheusRule e ExternalSecret do Alertmanager
```

## Alertas do envio de e-mail e da governança

| Alerta | Severidade | Condição |
|---|---|---|
| `UniplusEmailEnvioParado` | critical | última falha posterior ao último envio aceito (máximo em 2 h), por 15 min |
| `UniplusEmailFilaSemConsumidor` | critical | `max(uniplus_email_fila_atrasadas) > 0` por 10 min |
| `UniplusEmailMensagemMorta` | critical | `max(uniplus_email_mortas) > 0` |
| `UniplusEmailAmostraVencida` | warning | idade da amostra acima de 15 min |
| `UniplusEmailAmostraAusente` | warning | série da idade da amostra ausente por 15 min |
| `UniplusAutorizacaoAmostraVencida` | warning | idade da amostra da governança acima de 15 min |
| `UniplusAutorizacaoAmostraAusente` | warning | série ausente por 15 min, para a governança |
| `UniplusAutorizacaoDivergenciaDaGovernanca` | warning | `max(uniplus_autorizacao_divergencias_da_governanca) > 0` |

Nomes no Prometheus: pontos viram `_`, contadores ganham `_total` e gauges em segundos ganham
`_seconds`. Para validar as regras (sem binário local):

```bash
cd platform/observability/prometheus
docker run --rm --entrypoint promtool -v "$PWD:/w" -w /w prom/prometheus:v3.11.0 \
  check rules rules/uniplus-email-governanca.yaml
docker run --rm --entrypoint promtool -v "$PWD:/w" -w /w prom/prometheus:v3.11.0 \
  test rules tests/uniplus-email-governanca.test.yaml
```

O painel de acompanhamento é o `Uni+ — E-mail e governança`, no chart do Grafana.

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
