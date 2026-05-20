# cert-manager

Provisionamento automático de certificados TLS via Let's Encrypt (HTTP-01 + Traefik).

## Visão geral

Wrapper do chart oficial [jetstack/cert-manager](https://github.com/cert-manager/cert-manager). Roda no cluster do ambiente operacional (`standalone-compact`); o design multi-cluster permanece válido para o modelo 3-DC quando revivido.

**Upstream:** https://github.com/cert-manager/cert-manager
**Versão upstream empacotada:** v1.20.2 (ver `Chart.yaml`)

## Estratégia de emissão

- **HTTP-01 via Traefik** para hosts simples (cobertura desta PR)
- **DNS-01 wildcard** fora de escopo até decisão DIRSI sobre borda externa (ADR-004) — separado para evitar acoplar uma DNS API de provider ao Uni+ antes da decisão

Standalone usa apenas HTTP-01 (FQDN único `standalone.portaluni.com.br`). 3-DC poderá adicionar DNS-01 quando decisão de borda for tomada.

## Estrutura

```
platform/cert-manager/
├── Chart.yaml                                          # subchart upstream (alias=certManager)
├── values.yaml                                         # defaults Uni+
├── values.schema.json                                  # validação dos overrides
├── README.md                                           # este arquivo
└── templates/
    ├── clusterissuer-letsencrypt-staging.yaml          # ACME staging (gated)
    ├── clusterissuer-letsencrypt-prod.yaml             # ACME production (gated)
    └── networkpolicy.yaml                              # egress controlado
```

ServiceMonitor vem do subchart upstream (gateado por `certManager.prometheus.servicemonitor.enabled`). Wrapper não emite SM próprio.

## Bootstrap

Após o ApplicationSet sincronizar:

1. Pods do controller, webhook e cainjector sobem (3 Deployments)
2. CRDs `certificates.cert-manager.io`, `clusterissuers.cert-manager.io`, etc. são instaladas
3. ClusterIssuers permanecem desligados até `clusterIssuers.enabled: true` em algum environment
4. Habilitar requer **Traefik (#14) Synced/Healthy** — sem IngressClass `traefik`, HTTP-01 challenges falham
5. Habilitar via override:

   ```yaml
   # environments/standalone-compact/values.yaml
   clusterIssuers:
     enabled: true
   ```

6. ArgoCD reconcilia, ClusterIssuers ficam `Ready=True` após primeira interação ACME

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `certManager.enabled` | `true` | Liga o subchart |
| `certManager.crds.enabled` | `true` | Instala CRDs (Certificate, Issuer, etc.) |
| `certManager.crds.keep` | `true` | Não remove CRDs em uninstall |
| `certManager.replicaCount` | `1` | 1 em lab/standalone, 2+ em prod |
| `certManager.prometheus.servicemonitor.enabled` | `false` | Ligar quando #26 (Prometheus chart) estiver pronto |
| `clusterIssuers.enabled` | `false` | Habilitar APÓS Traefik (#14) estar pronto |
| `clusterIssuers.email` | `ctic@unifesspa.edu.br` | Registro ACME — recebe avisos de expiração |
| `clusterIssuers.ingressClass` | `traefik` | IngressClass que resolve HTTP-01 |
| `clusterIssuers.staging.enabled` | `true` | ACME staging (sem rate limit relevante) |
| `clusterIssuers.production.enabled` | `true` | ACME production (rate limit 50 certs/domain/week) |
| `networkPolicy.enabled` | `true` | Egress restrito a internet:443, kube-dns, K8s API |

## Como emitir um certificado

Importante: o `ingress-shim` do cert-manager só auto-gera `Certificate` a partir de `Ingress` (networking.k8s.io/v1) ou Gateway API — **não** de `IngressRoute` (CRD do Traefik). A annotation `cert-manager.io/cluster-issuer` é ignorada em IngressRoutes. Há duas opções:

**Opção A — Certificate explícito + IngressRoute referenciando o Secret** (recomendado quando o stack usa Traefik IngressRoute):

```yaml
# 1. Certificate explícito — cert-manager solicita e renova
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: portal-tls
  namespace: uniplus
spec:
  secretName: portal-tls           # Secret que cert-manager cria/atualiza
  issuerRef:
    name: letsencrypt-prod         # ou letsencrypt-staging para validação
    kind: ClusterIssuer
  dnsNames:
    - standalone.portaluni.com.br
---
# 2. IngressRoute consome o Secret pronto
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: portal
  namespace: uniplus
spec:
  entryPoints: [websecure]
  routes:
    - match: Host(`standalone.portaluni.com.br`)
      kind: Rule
      services:
        - name: uniplus-web
          port: 80
  tls:
    secretName: portal-tls         # mesmo nome do Certificate.spec.secretName
```

**Opção B — Ingress nativo + ingress-shim** (caminho automático):

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: portal
  namespace: uniplus
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  ingressClassName: traefik
  tls:
    - hosts: [standalone.portaluni.com.br]
      secretName: portal-tls
  rules:
    - host: standalone.portaluni.com.br
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: uniplus-web
                port: { number: 80 }
```

Para validação inicial, sempre começar com `letsencrypt-staging` (cert não confiável pelo browser mas sem rate limit). Após confirmar o fluxo, trocar para `letsencrypt-prod`.

## Renovação

Renovação automática 30 dias antes da expiração (default do cert-manager). Forçar renovação manual:

```bash
kubectl cmctl renew portal -n uniplus
# ou via annotation:
kubectl annotate certificate portal -n uniplus cert-manager.io/issue-temporary-certificate-
```

## Observabilidade

cert-manager expõe métricas Prometheus na porta `9402` (default upstream). O ServiceMonitor é gerado pelo próprio subchart quando `certManager.prometheus.servicemonitor.enabled: true` — manter desligado até o stack Prometheus (#26) estar no ar. Wrapper não emite SM próprio para evitar scrape duplicado.

Métricas chave:
- `certmanager_certificate_expiration_timestamp_seconds` — quando cada cert vai expirar
- `certmanager_http_acme_client_request_count` — chamadas ao ACME server
- `certmanager_certificate_ready_status` — gauge de saúde dos certs

## Network

NetworkPolicy do chart restringe egress dos Pods do operator a:
- Internet pública na porta 443 (ACME endpoints — não há IP estável para Let's Encrypt)
- kube-dns (UDP/TCP 53)
- Kubernetes API (TCP 6443/443) restrito ao service CIDR

Egress para internet exclui CIDRs RFC 1918 (já cobertos por outras regras).

Sem ingress (controller não recebe tráfego direto — webhook é gerenciado pelo subchart).

## Segurança

- ACME private keys ficam em Secrets gerenciados pelo cert-manager (`letsencrypt-{staging,prod}-account-key`)
- Email registrado no ACME é endereço institucional CTIC — alertas de expiração chegam ao canal correto
- Egress limitado por NetworkPolicy
- CRDs com `keep: true` evitam perda de Certificates/Orders se o chart for desinstalado por engano

## Referências

- [#3](https://github.com/unifesspa-edu-br/uniplus-infra/issues/3) — umbrella platform charts
- [#15](https://github.com/unifesspa-edu-br/uniplus-infra/issues/15) — esta task
- [#14](https://github.com/unifesspa-edu-br/uniplus-infra/issues/14) — Traefik (pré-requisito do HTTP-01)
- ADR-004 (borda externa — DNS-01 fica para depois)
- ADR-008 (topologia standalone)
