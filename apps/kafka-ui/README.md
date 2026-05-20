# kafka-ui (AKHQ)

Helm chart wrapper Uni+ para [AKHQ](https://github.com/tchiotludo/akhq) — Web UI de gerenciamento do cluster Apache Kafka. Conecta ao broker SASL_SSL no `data-host` (ADR-009) via SCRAM-SHA-512; autentica usuários via OIDC do realm `uniplus` no Keycloak local.

## Status

Provisionado em **standalone** (issue #139, sub-issue de #40 Epic standalone). Bloqueado por #138 (Kafka SASL_SSL hardening, mergeado em PR #140 + hotfix #141 — ADR-009).

## Arquitetura

```
Browser (admin Uni+)
  └── HTTPS via Traefik IngressRoute
       https://kafka-ui.standalone.portaluni.com.br
            └── AKHQ pod (apps/kafka-ui chart, namespace uniplus)
                 ├── OIDC client `kafka-ui` no realm `uniplus` (confidential)
                 ├── SCRAM admin via ESO (`secret/standalone/kafka/admin`)
                 ├── CA cert PEM via projected volume (mesmo Secret ESO)
                 └── conexão SASL_SSL → 10.2.2.11:9092
```

## Permissões via groups Keycloak → roles AKHQ

Mapping no `application.yml` renderizado pelo chart:

| Grupo Keycloak | Role AKHQ | Capacidades |
|---|---|---|
| `/admins/kafka` | `kafka-admins` | criar/deletar tópicos, gerenciar ACLs, alterar consumer groups, configurar broker |
| `/users/uniplus` | `kafka-readonly` | listar tópicos, inspecionar mensagens, ver consumer groups (sem write) |
| (sem grupo) | `no-roles` | sem acesso (default-group) |

## Pré-requisitos antes do ArgoCD sync

1. **Realm `uniplus` com client `kafka-ui` confidential criado** + mapper `groups` exportando membership em `groups` claim do JWT
2. **`secret/standalone/kafka/admin` em Vault** com keys `username`, `password`, `ca_cert` (criado no §13.2 do RUNBOOKS pós-hotfix #141)
3. **`secret/standalone/keycloak/clients/kafka-ui` em Vault** com `client_secret` do client OIDC (custódia manual via `vault kv put`)

Sem esses 3, ESOs ficam em `SecretNotFound` e o pod entra em `CreateContainerConfigError`.

## Configuração mínima para habilitar

Em `environments/standalone-compact/values.yaml`:

```yaml
kafkaUi:
  enabled: true
  kafka:
    bootstrapServers: 10.0.2.87:9092
  oidc:
    issuerUri: https://standalone.portaluni.com.br/auth/realms/uniplus
  ingress:
    enabled: true
    host: kafka-ui.standalone.portaluni.com.br
    tls:
      certManager:
        enabled: true
        clusterIssuer: letsencrypt-staging
  networkPolicy:
    dataHostCIDR: 10.0.2.0/24
```

## Operações comuns

Ver `docs/RUNBOOKS.md` §14 para procedimentos:

- §14.1 Pré-flight: secrets em Vault + client OIDC no realm
- §14.2 Smoke test (login admin → criar tópico → produzir/consumir → ver no UI)
- §14.3 Adicionar usuário ao grupo `/admins/kafka` no Keycloak
- §14.4 Troubleshooting (OIDC redirect, SCRAM auth, cert PKIX, NetworkPolicy)

## Trade-offs e limitações

- **AKHQ é stateless** — perda de pod sem impacto em state (estado vive no Kafka).
- **OIDC PKCE não suportado em provider customizado em 0.27.x** — usamos confidential client com `client_secret` em Vault. AKHQ é backend (não SPA), então confidential é correto arquiteturalmente.
- **Audit log de operações no AKHQ → SIEM** ainda não integrado (futuro hardening).
- **Multi-cluster** desligado — só `standalone-kafka` por enquanto. SP1/SP2/PA1 entram quando charts data/* aterrissarem (gap pré-existente, fora do escopo).

## Referências

- [AKHQ docs](https://akhq.io/docs/)
- [Apache Kafka 4.2 docs](https://kafka.apache.org/42/documentation.html)
- ADR-009 — Kafka SASL_SSL + SCRAM-SHA-512
- Issue #139 — escopo deste chart
