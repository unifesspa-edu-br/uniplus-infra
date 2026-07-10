# apicurio-registry

Apicurio Registry — schema registry compatível com a Confluent Schema Registry API. Storage SQL no Postgres standalone, autenticação OIDC via Keycloak realm `uniplus` com role-based authorization.

## Quando usar

Ative apenas em ambientes que precisam de schema/API artifact registry para validação de eventos Kafka (Avro, JSON Schema, Protobuf, OpenAPI, AsyncAPI). Em standalone roda com 1 réplica e DB compartilhado com os demais services do data-host.

## Pré-requisitos

| Recurso | De onde vem |
|---|---|
| Database `apicurio` + role `apicurio` no Postgres | `step_data_setup_apicurio_db` do `scripts/bootstrap-standalone.sh` |
| Senha do role no Vault | Custódia manual em `secret/standalone/postgres/apicurio` (RUNBOOKS §15.2) |
| Client OIDC `apicurio-registry` no realm uniplus | Import do realm pelo chart `keycloak-replica` |
| `client_secret` no Vault | Recuperado via `kcadm.sh` pós-import (RUNBOOKS §15.1) |
| Cert Let's Encrypt prod | cert-manager via `ingress.tls.certManager.clusterIssuer: letsencrypt-prod` |
| DNS público | `schema-registry.standalone.portaluni.com.br` → IP do k8s-host |

## Roles e mapeamento

Apicurio define 3 roles internas. Mapeamento via env `APICURIO_AUTH_ROLES_*` lê o valor exato do claim JWT (path = `groups`, full path Keycloak).

| Apicurio role | Permissão | Mapeado de | User exemplo |
|---|---|---|---|
| `sr-admin` | RW + admin (delete, configurar, exportar) | `/admins/kafka` | `jeferson.ferreira` |
| `sr-developer` | RW em artifacts | `/users/uniplus` | usuários gerais Uni+ |
| `sr-readonly` | leitura | (vazio — sem mapping default) | — |

Sem grupo no JWT = nenhuma role atribuída → todas as operações retornam 403 (anonymous read access OFF).

## Por que `auth.apicur.io` não é usado

Apicurio Registry vem com default `QUARKUS_OIDC_AUTH_SERVER_URL=https://auth.apicur.io/auth/realms/apicurio-local` apontando para um **Keycloak demo público mantido pela Red Hat**. Este chart **sempre** sobrescreve com `oidc.issuerUri` do nosso Keycloak local — sem SLA externo, sem users públicos, sem dependência de domínio fora da nossa zona.

## Endpoints úteis

- UI: `https://schema-registry.standalone.portaluni.com.br/ui` (login OIDC obrigatório)
- API V3 (Apicurio nativa): `/apis/registry/v3`
- API V2 (Confluent SR compat): `/apis/ccompat/v7`
- Health: `/apis/registry/v3/system/info` (Apicurio 3.2.4 desabilita `/q/health/*` — as probes do `deployment.yaml` usam este endpoint)
- Metrics: `/q/metrics` (Prometheus, scrape via `serviceMonitor.enabled: true`)

## Operação

Procedimentos detalhados em `docs/RUNBOOKS.md` §15 (deploy, custódia, smoke, troubleshooting, bootstrap inicial de schemas).
