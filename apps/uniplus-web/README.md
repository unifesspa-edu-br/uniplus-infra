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
    -f environments/lab-sp1/values.yaml
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
| `apps.portal.path` | `/portal` | Path prefix no Ingress |
| `apps.selecao.*` | similar | Mesma estrutura para Seleção |
| `apps.ingresso.*` | similar | Mesma estrutura para Ingresso |
| `ingress.host` | `uniplus.unifesspa.edu.br` | Hostname público |
| `ingress.tls.enabled` | `true` | TLS via cert-manager |

## Override por ambiente

Os ambientes em `environments/` definem overrides específicos:

- `lab-sp1/values.yaml` — réplicas reduzidas, hostname `uniplus-lab.shop`
- `lab-sp2/values.yaml` — idem, mas com selecao primary
- `prod-sp1/values.yaml` — produção, hostname institucional
- `prod-sp2/values.yaml` — idem

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra). Veja [CONTRIBUTING.md](../../CONTRIBUTING.md).
