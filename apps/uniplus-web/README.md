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
| `apps.portal.pathPrefix` | `""` | Subpath opcional (Host + PathPrefix, sem StripPrefix). Vazio → `Host()` puro; `/portal` e `/portal/` são normalizados para o mesmo mount point e `APP_BASE_HREF` |
| `apps.selecao.host` / `apps.ingresso.host` | `""` | Hostname público de cada SPA |
| `apps.selecao.pathPrefix` / `apps.ingresso.pathPrefix` | `""` | Mesmo comportamento de subpath do Portal |
| `ingress.enabled` | `true` | Habilita os IngressRoutes das SPAs ativas |
| `ingress.tls.enabled` | `true` | Configura TLS para os IngressRoutes |
| `ingress.rootRedirect.enabled` | `false` | Redireciona a raiz nua do host (`Host()` sem `PathPrefix`, sem app próprio) pra um dos apps habilitados. Só relevante em ambientes com múltiplos apps sob o mesmo host (subpath) — não muda nada quando cada app tem host próprio |
| `ingress.rootRedirect.to` | `""` | Path de destino do redirect, com barra final (ex.: `/portal/`) — precisa bater com o `pathPrefix` de um app habilitado, senão o chart falha o render |

## Roteamento path-based

Cada SPA define o próprio `host` e `pathPrefix`. Quando há prefixo, o chart
gera `Host() && PathPrefix()` sem middleware de `StripPrefix`, e injeta o
mesmo mount point em `APP_BASE_HREF` para a imagem Angular. Assim, o Nginx e o
frontend recebem o caminho completo.

```yaml
uniplusWeb:
  apps:
    portal:
      host: uniplus-hml.192.168.21.134.nip.io
      pathPrefix: /portal
    selecao:
      host: uniplus-hml.192.168.21.134.nip.io
      pathPrefix: /selecao
    ingresso:
      host: uniplus-hml.192.168.21.134.nip.io
      pathPrefix: /ingresso
```

`pathPrefix` vazio ou `/` mantém a regra `Host()` pura. O valor `/portal/` é
normalizado para `/portal`, evitando regras duplicadas e mantendo o
`APP_BASE_HREF` consistente.

## Override por ambiente

O único ambiente operacional é `standalone-compact`:

- `standalone-compact/values.yaml` — 1 réplica por app, hostname `*.standalone.portaluni.com.br`

Quando o modelo 3-DC (`lab-*` / `prod-*` em SP1/SP2/PA1) for revivido, novos environments serão derivados a partir do standalone-compact.

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra). Veja [CONTRIBUTING.md](../../CONTRIBUTING.md).
