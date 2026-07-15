# uniplus-web

Chart Helm para os frontends Angular do Uni+ (Portal, Seleção, Ingresso).

## Visão geral

Este chart deploya 3 aplicações Angular do workspace [uniplus-web](https://github.com/unifesspa-edu-br/uniplus-web) como Deployments independentes em Kubernetes:

- **Portal** — `/portal` (default em `/`)
- **Seleção** — `/selecao`
- **Ingresso** — `/ingresso`

Cada app é servida por Nginx, com configuração de cache e compressão otimizada.

## Pré-requisitos

- Kubernetes 1.30+
- Helm 3.x
- Traefik (ou outro Ingress Controller compatível)
- cert-manager (para TLS automático)

## Instalação

Este chart **não é instalado manualmente**. O ArgoCD aplica via `ApplicationSet` definido em `argocd/applicationset.yaml`.

Para teste local apenas:

```bash
helm install uniplus-web ./apps/uniplus-web \
    --namespace uniplus \
    --create-namespace \
    -f environments/standalone-compact/values.yaml
```

## Estrutura de templates

```
templates/
├── deployment.yaml          # 1 Deployment por app (Portal, Seleção, Ingresso)
├── service.yaml             # 1 Service por app
├── ingressroute.yaml        # IngressRoute Traefik com PathPrefix
├── networkpolicy.yaml       # Network policies restritivas
├── servicemonitor.yaml      # Auto-discovery pelo Prometheus
├── pdb.yaml                 # PodDisruptionBudget
└── _helpers.tpl             # Helpers Helm reutilizáveis
```

## Configuração principal

| Parâmetro | Default | Descrição |
|-----------|---------|-----------|
| `apps.portal.enabled` | `true` | Habilita Portal |
| `apps.portal.replicas` | `2` | Réplicas do Portal |
| `apps.portal.host` | `""` | Hostname público do app (obrigatório quando ingress habilitado) |
| `apps.portal.pathPrefix` | `""` | Subpath opcional (Host + PathPrefix, sem StripPrefix). Vazio → `Host()` puro |
| `apps.selecao.*` | similar | Mesma estrutura para Seleção |
| `apps.ingresso.*` | similar | Mesma estrutura para Ingresso |
| `ingress.host` | `uniplus.unifesspa.edu.br` | Hostname público |
| `ingress.tls.enabled` | `true` | TLS via cert-manager |

## Override por ambiente

O único ambiente operacional é `standalone-compact`:

- `standalone-compact/values.yaml` — 1 réplica por app, hostname `*.standalone.portaluni.com.br`

Quando o modelo 3-DC (`lab-*` / `prod-*` em SP1/SP2/PA1) for revivido, novos environments serão derivados a partir do standalone-compact.

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra). Veja [CONTRIBUTING.md](../../CONTRIBUTING.md).
