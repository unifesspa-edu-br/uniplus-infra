# prometheus

Stack Prometheus + Operator (CRDs ServiceMonitor/PodMonitor) + Alertmanager + node-exporter + kube-state-metrics.

## Visão geral

Wrapper do chart oficial [prometheus-community/kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack). Roda no cluster do ambiente operacional (`standalone-compact`); o design multi-cluster permanece válido para o modelo 3-DC quando revivido. Em PA1 fica desligado por default — PA1 hospeda agregação separada com retenção longa.

Grafana NÃO faz parte deste chart (vai para `platform/observability/grafana/`, sub-issue #27). O subchart upstream vem com Grafana habilitado por default — desligamos explicitamente aqui.

**Upstream:** https://github.com/prometheus-community/helm-charts
**Versão upstream empacotada:** kube-prometheus-stack 84.5.0 (Operator v0.90.1)

## Estrutura

```
platform/observability/prometheus/
├── Chart.yaml                              # subchart umbrella (alias=kubePrometheusStack)
├── values.yaml                             # defaults Uni+
├── values.schema.json                      # validação dos overrides
├── README.md                               # este arquivo
└── templates/                              # delegado ao subchart (placeholder)
```

## Bootstrap

Após o ApplicationSet sincronizar:

1. Pods sobem: prometheus-operator, prometheus-server, alertmanager, node-exporter (DaemonSet), kube-state-metrics
2. CRDs `servicemonitors.monitoring.coreos.com`, `podmonitors`, `prometheusrules`, `alertmanagers`, etc. são instaladas
3. Charts `platform/external-secrets/`, `platform/cert-manager/`, `platform/traefik/`, `platform/vault/` podem habilitar `serviceMonitor.enabled: true` em seus values — Prometheus passa a scrape automaticamente (selector aceita TODOS os SMs do cluster, ver `serviceMonitorSelectorNilUsesHelmValues: false` em values.yaml)
4. Alertmanager fica ativo mas sem receivers reais (apenas registra no log) — receivers serão adicionados em sub-issue separada

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `kubePrometheusStack.enabled` | `true` | Liga o subchart |
| `kubePrometheusStack.grafana.enabled` | `false` | Grafana fica em chart separado (#27) |
| `kubePrometheusStack.prometheus.prometheusSpec.replicas` | `1` | 1 em standalone/lab, 2+ em prod (override) |
| `kubePrometheusStack.prometheus.prometheusSpec.retention` | `7d` | Standalone alinha com `environments/standalone-compact/values.yaml` |
| `kubePrometheusStack.prometheus.prometheusSpec.retentionSize` | `8GiB` | Storage 10Gi com folga pra WAL |
| `kubePrometheusStack.prometheus.ingress.enabled` | `false` | Habilitar atrás de OIDC + IP allowlist |
| `kubePrometheusStack.alertmanager.enabled` | `true` | Receiver placeholder "null" (apenas log) |
| `kubePrometheusStack.crds.enabled` | `true` | Instala ServiceMonitor/PodMonitor/etc. |
| `kubePrometheusStack.crds.upgradeJob.enabled` | `false` | ArgoCD gerencia upgrades |
| `kubePrometheusStack.kubeControllerManager.enabled` | `false` | K3s embute no kubelet |
| `kubePrometheusStack.kubeScheduler.enabled` | `false` | Idem |
| `kubePrometheusStack.kubeProxy.enabled` | `false` | K3s roda kube-proxy mas binda métricas em 127.0.0.1 — SM padrão não scrapeia |
| `kubePrometheusStack.kubeEtcd.enabled` | `false` | K3s embarca etcd sem endpoint client-cert separado |

## Como expor métricas de outros charts

Após este chart estar Synced/Healthy, outros charts da plataforma podem habilitar seus ServiceMonitors via override no environment:

```yaml
# environments/standalone-compact/values.yaml
externalSecrets:
  serviceMonitor:
    enabled: true       # ESO scrapeado pelo Prometheus

certManager:
  prometheus:
    servicemonitor:
      enabled: true     # cert-manager scrapeado

traefik:
  metrics:
    prometheus:
      service:
        enabled: true
      serviceMonitor:
        enabled: true   # Traefik scrapeado

vault:
  serviceMonitor:
    enabled: true       # Vault scrapeado
```

A flag `serviceMonitorSelectorNilUsesHelmValues: false` no `prometheusSpec` faz o Prometheus aceitar SMs de qualquer release/namespace — não há necessidade de label sync entre charts.

## Storage

O stack precisa de PVCs para Prometheus (10Gi default) e Alertmanager (2Gi). Em standalone, `storageClassName` herda da `standalone-local-nvme` (chart `platform/storage/`). Cada environment pode override via:

```yaml
# environments/<env>/values.yaml
kubePrometheusStack:
  prometheus:
    prometheusSpec:
      storageSpec:
        volumeClaimTemplate:
          spec:
            storageClassName: <env-specific-sc>
```

## Componentes K3s

Por default o subchart upstream tenta scrape kube-controller-manager, kube-scheduler, kube-proxy e etcd. Em K3s controller-manager e scheduler rodam dentro do binário único do K3s (sem endpoint HTTP separado), kube-proxy roda mas binda as métricas em `127.0.0.1` por default (SM padrão não consegue scrape sem mudar `metricsBindAddress: 0.0.0.0`), e etcd está embarcado sem endpoint client-cert separado. Desligamos esses 4 ServiceMonitors no chart wrapper para evitar alertas falsos `*Down` desde a primeira sincronização. Em distribuições K8s upstream (não-K3s) reabilitar via env override.

## Network

O subchart upstream tem suas próprias NetworkPolicies (gateadas por `kubePrometheusStack.prometheus.networkPolicy.enabled` etc.). O wrapper Uni+ não duplica — habilitar via env values quando necessário.

Em standalone (single-host, default-allow no K3s sem CNI mais restritivo), as NPs do subchart podem ficar desligadas. Em prod 3-DC (Calico ou Cilium com default-deny), habilitar no env override.

## Segurança

- Pod security: defaults do upstream (non-root, runAsUser 65534 para Prometheus)
- IngressRoute desligado por default — habilitar atrás de OIDC + IP allowlist
- Receivers do Alertmanager começam como placeholder "null" — adicionar receivers reais em sub-issue separada

## Referências

- [#3](https://github.com/unifesspa-edu-br/uniplus-infra/issues/3) — umbrella platform charts
- [#26](https://github.com/unifesspa-edu-br/uniplus-infra/issues/26) — esta task
- [#27](https://github.com/unifesspa-edu-br/uniplus-infra/issues/27) — Grafana (chart separado)
- [#28](https://github.com/unifesspa-edu-br/uniplus-infra/issues/28) — Loki (logs)
- [#29](https://github.com/unifesspa-edu-br/uniplus-infra/issues/29) — Tempo (traces)
- [#30](https://github.com/unifesspa-edu-br/uniplus-infra/issues/30) — OpenTelemetry Collector (pipeline)
- ADR-008 (topologia standalone) — retenção curta justificada
