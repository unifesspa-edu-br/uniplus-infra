# grafana

UI para visualização de métricas (Prometheus), logs (Loki) e traces (Tempo).

## Visão geral

Wrapper do chart oficial [grafana/grafana](https://github.com/grafana/helm-charts/tree/main/charts/grafana). Roda em cada cluster (lab-{sp1,sp2}, prod-{sp1,sp2}, standalone). Em PA1 fica desligado por default — PA1 hospeda agregação separada.

Vem como chart separado (não bundled no `kube-prometheus-stack`) para facilitar versionamento independente e desligar Grafana em envs sem UI (PA1, ou qualquer cluster onde apenas a coleta importe).

**Upstream:** https://github.com/grafana/helm-charts
**Versão upstream empacotada:** grafana 10.5.15 (Grafana v12.3.1)

## Estrutura

```
platform/observability/grafana/
├── Chart.yaml                              # subchart upstream (sem alias)
├── values.yaml                             # defaults Uni+ + datasources
├── values.schema.json                      # validação dos overrides
├── README.md                               # este arquivo
└── templates/                              # delegado ao subchart (placeholder)
```

## Bootstrap

Após o ApplicationSet sincronizar:

1. Pod do Grafana sobe (1 réplica em standalone/lab; 2+ em prod via override)
2. PVC `grafana` (5Gi default) é provisionado para o sqlite interno
3. Datasource Prometheus pré-configurado via ConfigMap (sidecar carrega no boot)
4. Loki/Tempo datasources gateados — habilitar em env quando charts (#28/#29) aterrissarem
5. Sidecar `grafana_dashboard=1` carrega dashboards de qualquer ConfigMap labelado dessa forma em qualquer namespace (search-namespace=ALL)
6. Login default `admin` / `uniplus` (PLACEHOLDER) — sobrescrever via ESO + Vault em prod/standalone

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `grafana.enabled` | `true` | Liga o subchart |
| `grafana.replicas` | `1` | 1 em standalone/lab, 2+ em prod (override) |
| `grafana.persistence.size` | `5Gi` | PVC para o sqlite interno |
| `grafana.adminPassword` | `uniplus` | PLACEHOLDER — sobrescrever via ESO + Vault em prod/standalone |
| `grafana.serviceMonitor.enabled` | `false` | Ligar quando Prometheus (#26) consumidor estiver pronto e Grafana scrapeado |
| `grafana.ingress.enabled` | `false` | Wrapper usa IngressRoute do Traefik (futuro template gated) |
| `grafana.sidecar.dashboards.enabled` | `true` | Auto-carrega dashboards de ConfigMaps labelados |
| `networkPolicy.enabled` | `false` | Subchart tem NPs próprias — habilitar em env se necessário |

## Datasource Prometheus — URL por environment

O default em `values.yaml` usa um placeholder `CLUSTER` no FQDN do Service Prometheus:

```yaml
url: http://platform-observability-prometheus-CLUSTER-prometheus.observability-prometheus.svc.cluster.local:9090
```

Isso porque o ApplicationSet usa o cluster name no release (`{{.name}}` em `argocd/applicationset.yaml`) e o Service do Prometheus leva esse nome. Cada environment DEVE sobrescrever:

```yaml
# environments/standalone/values.yaml
grafana:
  datasources:
    datasources.yaml:
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          uid: prometheus
          access: proxy
          url: http://platform-observability-prometheus-uniplus-standalone-prometheus.observability-prometheus.svc.cluster.local:9090
          isDefault: true
          jsonData:
            timeInterval: 30s
```

Pattern por env:
- standalone: `platform-observability-prometheus-uniplus-standalone-prometheus.observability-prometheus.svc...`
- lab-sp1: `platform-observability-prometheus-lab-sp1-prometheus.observability-prometheus.svc...`
- lab-sp2: `platform-observability-prometheus-lab-sp2-prometheus.observability-prometheus.svc...`
- prod-sp1/sp2: `platform-observability-prometheus-prod-{sp1,sp2}-prometheus.observability-prometheus.svc...`

(Quando `platform/observability/prometheus/` ganhar `fullnameOverride`, esse pattern simplifica — issue separada se valer a pena.)

## Provisionar dashboards Uni+

Dashboards customizados são empacotados como ConfigMaps com label `grafana_dashboard=1`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: portal-dashboard
  labels:
    grafana_dashboard: "1"   # sidecar do Grafana auto-carrega
data:
  portal.json: |
    { "dashboard": { ... JSON do dashboard ... } }
```

Os ConfigMaps podem viver em qualquer namespace (sidecar usa `searchNamespace: ALL`). Dashboards iniciais (cluster, K8s, node-exporter, kube-state-metrics) são carregados automaticamente do upstream `kube-prometheus-stack`.

## SSO via OIDC (Keycloak)

`grafana.ini` traz placeholder para integração OIDC (ADR-003). Quando `apps/keycloak-replica` tiver o realm `uniplus` com client `grafana` configurado, sobrescrever em env values:

```yaml
grafana:
  grafana.ini:
    server:
      root_url: https://grafana.standalone.portaluni.com.br
    auth.generic_oauth:
      enabled: true
      name: Keycloak
      allow_sign_up: true
      client_id: grafana
      client_secret: $__file{/etc/secrets/oidc-client-secret}  # via ESO
      scopes: openid email profile
      auth_url: https://standalone.portaluni.com.br/auth/realms/uniplus/protocol/openid-connect/auth
      token_url: http://platform-keycloak-replica-uniplus-standalone-keycloakx-http.keycloak.svc.cluster.local:8080/realms/uniplus/protocol/openid-connect/token
      api_url: http://platform-keycloak-replica-uniplus-standalone-keycloakx-http.keycloak.svc.cluster.local:8080/realms/uniplus/protocol/openid-connect/userinfo
```

(URLs exatas dependem do chart Keycloak quando aterrissar.)

## Storage

PVC default 5Gi (sqlite interno do Grafana). Em standalone, `storageClassName` herda da `standalone-local-nvme` quando configurado em env values:

```yaml
# environments/standalone/values.yaml
grafana:
  persistence:
    storageClassName: standalone-local-nvme
```

Mesmo override para os demais envs (lab/prod-local-nvme).

## Network

O subchart upstream tem NetworkPolicies próprias (gateadas por `grafana.networkPolicy.enabled`). Wrapper Uni+ não duplica — habilitar via env values quando necessário.

## Segurança

- Pod roda como non-root (UID 472, default upstream)
- `adminPassword: uniplus` é PLACEHOLDER — JAMAIS commitar senha real; sobrescrever via ESO apontando para `secret/grafana/admin` no Vault
- IngressRoute desligada por default — habilitar atrás de OIDC (depois que Keycloak chart aterrissar)
- `analytics.reporting_enabled: false` (não envia telemetria pra Grafana Labs)

## Referências

- [#3](https://github.com/unifesspa-edu-br/uniplus-infra/issues/3) — umbrella platform charts
- [#27](https://github.com/unifesspa-edu-br/uniplus-infra/issues/27) — esta task
- [#26](https://github.com/unifesspa-edu-br/uniplus-infra/issues/26) — Prometheus (datasource principal — mergeado)
- [#28](https://github.com/unifesspa-edu-br/uniplus-infra/issues/28) — Loki (datasource futuro)
- [#29](https://github.com/unifesspa-edu-br/uniplus-infra/issues/29) — Tempo (datasource futuro)
- ADR-003 (OIDC federado Gov.br via Keycloak)
