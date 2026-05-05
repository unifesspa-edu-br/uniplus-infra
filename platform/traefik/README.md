# traefik

Traefik IngressController v3 — entrypoints HTTP/HTTPS, IngressRoute CRDs, middlewares (security headers, compress).

## Visão geral

Wrapper do chart oficial [traefik/traefik-helm-chart](https://github.com/traefik/traefik-helm-chart). Roda em cada cluster (lab-{sp1,sp2}, prod-{sp1,sp2}, standalone). Em PA1 pode ficar desligado — não há ingress público lá.

**Upstream:** https://github.com/traefik/traefik-helm-chart
**Versão upstream empacotada:** v3.6.15 (chart 39.0.9)

K3s vem com Traefik pré-instalado por default. O `scripts/bootstrap-standalone.sh` desabilita explicitamente esse Traefik default (`--disable traefik`) para que este chart wrapper seja a única instância no cluster — sem conflito de IngressClass nem de bind 80/443. Re-executar o bootstrap após mudanças nesse script aplica o reset (K3s recria os manifests de bundled apps em cada start sem `--disable`).

## Estrutura

```
platform/traefik/
├── Chart.yaml                                  # subchart upstream (sem alias)
├── values.yaml                                 # defaults Uni+
├── values.schema.json                          # validação dos overrides
├── README.md                                   # este arquivo
└── templates/
    ├── middleware-headers-security.yaml        # HSTS, X-Frame, etc. (gated)
    ├── middleware-compress.yaml                # gzip/br (gated)
    └── networkpolicy.yaml                      # ingress 80/443 + egress controlado
```

ServiceMonitor + dashboard IngressRoute vêm do subchart upstream (gateados por `traefik.metrics.prometheus.serviceMonitor.enabled` e `traefik.ingressRoute.dashboard.enabled`). Wrapper não emite SM próprio.

## Bootstrap

Após o ApplicationSet sincronizar:

1. Pod do Traefik sobe (1 réplica em standalone/lab; 2+ em prod via override)
2. CRDs `ingressroutes.traefik.io`, `middlewares.traefik.io`, `serverstransports.traefik.io`, etc. são instaladas
3. IngressClass `traefik` (default do cluster) fica disponível
4. 2 Middlewares Uni+ ficam prontos (headers-security, compress)
5. Em standalone, hostPort binda 0.0.0.0:80 e 0.0.0.0:443 direto na VM com IP público
6. Em prod, Service `LoadBalancer` provisiona um LB do provider (override por env)

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `traefik.enabled` | `true` | Liga o subchart |
| `traefik.deployment.replicas` | `1` | 1 em lab/standalone, 2+ em prod (override) |
| `traefik.service.type` | `NodePort` | `LoadBalancer` em prod (override) |
| `traefik.ports.web.hostPort` | `80` | Bind direto na VM (standalone) |
| `traefik.ports.websecure.hostPort` | `443` | Bind direto na VM (standalone) |
| `traefik.ingressClass.name` | `traefik` | Referenciado pelo cert-manager (#15) |
| `traefik.ingressRoute.dashboard.enabled` | `false` | Habilitar atrás de OIDC + IP allowlist |
| `traefik.metrics.prometheus.serviceMonitor.enabled` | `false` | Ligar quando #26 (Prometheus) chegar |
| `middlewares.headersSecurity.enabled` | `true` | HSTS, frameDeny, nosniff, referrer-policy |
| `middlewares.compress.enabled` | `true` | gzip/br nas respostas |
| `networkPolicy.enabled` | `true` | Ingress 80/443 + egress aos namespaces das apps |
| `networkPolicy.appNamespaces` | `[uniplus, vault, keycloak]` | Namespaces dos backends — ajustar por env |

## Como criar uma IngressRoute em apps Uni+

Padrão de IngressRoute (Traefik CRD) consumindo os middlewares Uni+:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: portal
  namespace: uniplus
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`<env-fqdn>`)              # ex.: standalone.portaluni.com.br
      kind: Rule
      middlewares:
        - name: uniplus-headers-security     # nome FIXO do middleware Uni+
          namespace: traefik
        - name: uniplus-compress
          namespace: traefik
      services:
        - name: uniplus-web
          port: 80
  tls:
    secretName: portal-tls  # preenchido por cert-manager (ver platform/cert-manager/README.md)
```

Os middlewares têm **nomes fixos** (`uniplus-headers-security`, `uniplus-compress`) e vivem no namespace onde o Traefik está instalado (geralmente `traefik`) — independente do release name dinâmico do ApplicationSet. Substituir `<env-fqdn>` pelo FQDN do environment (definido em `environments/<env>/values.yaml` sob `ingress.host`).

## Pathing standalone

FQDN único `standalone.portaluni.com.br` com pathing controlado pelo Traefik:

| Path | Backend |
|---|---|
| `/` | `apps/uniplus-web` (portal Angular) |
| `/auth/*` | `apps/keycloak-replica` |
| `/api/portal/*` | `apps/uniplus-api-portal` |
| `/api/ingresso/*` | `apps/uniplus-api-ingresso` |
| `/api/selecao/*` | `apps/uniplus-api-selecao` |

IngressRoutes específicas serão adicionadas pelos charts de cada app (sub-issues da Story #99 de validação integrada).

## Observabilidade

Métricas Prometheus na porta 9100 (default upstream), formato Prometheus. ServiceMonitor vem do próprio subchart quando `traefik.metrics.prometheus.serviceMonitor.enabled: true` — manter desligado até o stack Prometheus (#26) estar no ar.

Logs em **JSON** (general + access) — pronto para coleta por Loki (#28) sem parser intermediário.

Métricas chave:
- `traefik_entrypoint_requests_total` — total de requests por entrypoint
- `traefik_entrypoint_request_duration_seconds` — histograma de latência
- `traefik_router_requests_total{code}` — código de status por rota
- `traefik_service_open_connections` — conexões abertas por backend

## Network

NetworkPolicy do chart:

- **Ingress**: 8000 (web) e 8443 (websecure) abertos a qualquer origem (firewall externo controla a borda); 9100 (métricas) aberto a qualquer namespace para Prometheus.
- **Egress**: namespaces das apps (`uniplus`, `vault`, `keycloak` por default — ajustar por env), namespace `cert-manager` (challenge solver Pods do HTTP-01), kube-dns, Kubernetes API.

## Segurança

- Pod roda como non-root (UID 65532), `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]` + `add: [NET_BIND_SERVICE]` para abrir portas privilegiadas via hostPort
- Headers de segurança aplicados via Middleware (HSTS 1 ano, X-Frame-Options DENY, X-Content-Type-Options nosniff, Referrer-Policy strict-origin-when-cross-origin)
- `X-Powered-By` e `Server` removidos das respostas (não revela stack)
- Dashboard interno desligado por default — habilitar atrás de OIDC + IP allowlist
- HSTS preload `false` por default; ligar só após confirmação institucional de inclusão na lista do Chrome

## Referências

- [#3](https://github.com/unifesspa-edu-br/uniplus-infra/issues/3) — umbrella platform charts
- [#14](https://github.com/unifesspa-edu-br/uniplus-infra/issues/14) — esta task
- [#15](https://github.com/unifesspa-edu-br/uniplus-infra/issues/15) — cert-manager (consome a IngressClass `traefik`)
- ADR-004 (borda externa)
- ADR-008 (topologia standalone)
