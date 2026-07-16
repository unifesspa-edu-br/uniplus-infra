# uniplus-api-portal

API .NET 10 do módulo Portal — conteúdo institucional e perfis

> **Status:** chart funcional para implantação GitOps do Portal.

## Visão geral

Componente da plataforma Uni+. Veja [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) para contexto.

## Pré-requisitos

- Kubernetes 1.30+
- Helm 3.x
- Vault + External Secrets Operator (para secrets)

## Roteamento path-based

Para expor a API do Portal junto de outros serviços sob o mesmo FQDN, configure
`uniplusApiPortal.ingress.pathPrefix`. O chart cria uma regra Traefik
`Host() && PathPrefix()` sem middleware de `StripPrefix`: o controller do
Portal recebe o caminho completo, incluindo `/api/portal`.

```yaml
uniplusApiPortal:
  ingress:
    enabled: true
    host: uniplus-api-hml.192.168.21.134.nip.io
    pathPrefix: /api/portal
```

`pathPrefix` é opcional. Vazio ou ausente mantém a rota `Host()` pura dos
ambientes existentes, sem alteração no caminho encaminhado ao serviço.

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `uniplusApiPortal.ingress.enabled` | `false` | Habilita a criação do IngressRoute Traefik |
| `uniplusApiPortal.ingress.host` | `""` | Hostname obrigatório quando o ingresso está habilitado |
| `uniplusApiPortal.ingress.pathPrefix` | `""` | Subpath opcional. Preenchido gera `Host() && PathPrefix()` sem `StripPrefix`; vazio mantém `Host()` puro |
| `uniplusApiPortal.ingress.tls.enabled` | `true` | Referencia o Secret TLS configurado para o ambiente |

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra).
