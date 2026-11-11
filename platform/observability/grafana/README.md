# observability/grafana

Grafana para métricas (Prometheus), logs (Loki) e traces (Tempo). Wrapper sobre o chart oficial
[grafana/grafana](https://github.com/grafana/helm-charts/tree/main/charts/grafana), separado do
`kube-prometheus-stack` para versionar e ligar de forma independente.

**Versão empacotada:** grafana 10.5.15 (Grafana 12.3.1).

## Estrutura

```
platform/observability/grafana/
├── Chart.yaml
├── values.yaml            # defaults e datasources
├── values.schema.json
├── dashboards/            # JSON dos dashboards Uni+ (pasta "Uni+")
└── templates/
    ├── dashboards.yaml    # um ConfigMap por dashboard, lido pelo sidecar
    ├── externalsecret.yaml
    └── ingressroute.yaml
```

## Service

Em um release chamado `platform-observability-grafana`, o Service é `platform-observability-grafana`
(porta 80) no namespace `observability-grafana`. O helper do wrapper se chama
`uniplus-grafana.fullname`, e não `grafana.fullname`, porque os templates do Helm são globais e o
segundo nome colidiria com o do subchart, renomeando o Service dele.

## Conta de administrador

O Secret vem do Vault por ExternalSecret (`grafana.externalSecrets.admin`), sem senha nos values:

```yaml
grafana:
  admin:
    existingSecret: grafana-admin
  externalSecrets:
    admin:
      enabled: true
      vaultPath: grafana/admin    # propriedades username e password
      secretName: grafana-admin   # igual a admin.existingSecret
```

`provisionar-observabilidade.sh` grava `plataforma/grafana/admin`. A store `plataforma` precisa
atender o namespace `observability-grafana`.

## Datasources

Três, com os uids que os dashboards usam:

| uid | Aponta para |
|---|---|
| `prometheus` (padrão) | `platform-observability-pro-prometheus.observability-prometheus:9090` |
| `loki` | `platform-observability-loki.observability-loki:3100` |
| `tempo` | `platform-observability-tempo.observability-tempo:3200`, com `tracesToLogsV2` para o Loki e service map sobre o Prometheus |

Os nomes valem para releases `platform-observability-<componente>`; com outro nome de release, o
ambiente sobrescreve as URLs.

## Rota

`grafana.ingressRoute` cria uma IngressRoute do Traefik (desligada por padrão). `host` é
obrigatório. Com `pathPrefix` vazio o Grafana responde na raiz do host; com prefixo, `root_url` e
`serve_from_sub_path: true` precisam acompanhar. O Secret do certificado precisa existir no
namespace `observability-grafana`.

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `grafana.replicas` | `1` | |
| `grafana.persistence.size` | `5Gi` | PVC do sqlite; a StorageClass vem do ambiente |
| `grafana.admin.existingSecret` | `""` | Secret da conta de administrador |
| `grafana.externalSecrets.admin.enabled` | `false` | Cria o Secret a partir do Vault |
| `grafana.ingressRoute.enabled` | `false` | |
| `grafana.sidecar.dashboards.enabled` | `true` | Carrega ConfigMaps com `grafana_dashboard=1` |
| `grafana.serviceMonitor.enabled` | `false` | |

## Validação

```bash
helm dependency update platform/observability/grafana
helm template platform-observability-grafana platform/observability/grafana \
  -f environments/uniplus-prd/values.yaml --namespace observability-grafana
```

## Segurança

- O pod roda como UID 472, sem root.
- Nenhuma senha vive no repositório; a conta vem do Vault.
- A rota só deve existir atrás do middleware de rede institucional.
- `analytics.reporting_enabled: false`: sem telemetria para a Grafana Labs.
