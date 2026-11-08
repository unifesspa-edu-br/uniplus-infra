# Caminhos dos segredos no Vault

O Vault tem um KV v2 por sistema e ambiente. Cada KV é lido por uma `ClusterSecretStore` própria, com papel, ServiceAccount e política próprios, restrita aos namespaces do dono (ver [`platform/external-secrets`](../platform/external-secrets/README.md)).

| Sistema | KV (`<amb>` = `prd` ou `hml`) | Store | Namespaces atendidos |
|---|---|---|---|
| Uni+ | `uniplus-<amb>` | `uniplus` | `uniplus` |
| Geo | `geo-<amb>` | `geo` | `geo` |
| Plataforma | `plataforma-<amb>` | `plataforma` | namespaces de plataforma do ambiente (`kes`, `kafka-ui`, `redis-ui`, `apicurio-registry`, `keycloak-replica`, `observability-*`) |

Os charts guardam só o nome da store e o caminho interno (sem KV nem prefixo). Os scripts de `scripts/servicos-no-host/` recebem `<sistema>/<caminho interno>` e resolvem o KV pelo `AMBIENTE` (`prd` por padrão).

## Segredo compartilhado

Um sistema não lê o KV de outro. O segredo usado por mais de um sistema é gravado no KV de cada um (os scripts de semente fazem isso):

| Segredo | Gravado em |
|---|---|
| `redis` | `uniplus`, `geo`, `plataforma` |
| `minio/root` | `uniplus`, `plataforma` |
| `kafka/admin` | `uniplus`, `plataforma` |
| `smtp` | `uniplus`, `plataforma` (vem de fora dos scripts) |

Ao trocar um desses segredos, trocar em todos os KVs da linha.

## Mapa antigo para novo

O caminho antigo ficava no mount `secret/`, sob um prefixo único do ambiente (`secret/<prefixo>/<caminho>`); a coluna abaixo lista só o `<caminho>`.

| Caminho antigo | KV | Caminho novo |
|---|---|---|
| `postgres/uniplus` | `uniplus-<amb>` | `postgres` |
| `postgres/portal` | `uniplus-<amb>` | `postgres-portal` |
| `uniplus-api-host/encryption` | — | descartado: a API cifra pelo Transit (abaixo) |
| `keycloak/clients/uniplus-api-host` | `uniplus-<amb>` | `keycloak/uniplus-api-host` |
| `keycloak/clients/uniplus-api-portal` | `uniplus-<amb>` | `keycloak/uniplus-api-portal` |
| `keycloak/clients/uniplus-api-selecao` (client OAuth do Geo) | `uniplus-<amb>` | `keycloak/uniplus-api-selecao` |
| `minio/arquivos-candidato-api` | `uniplus-<amb>` | `minio/arquivos-candidato-api` |
| `minio/arquivos-candidato-verificador` | `uniplus-<amb>` | `minio/arquivos-candidato-verificador` |
| `rabbitmq/api` | `uniplus-<amb>` | `rabbitmq/api` |
| `rabbitmq/verificador` | `uniplus-<amb>` | `rabbitmq/verificador` |
| `kafka/uniplus-api-registro-acesso-svc` | `uniplus-<amb>` | `kafka/uniplus-api-registro-acesso-svc` |
| `kafka/ca` | `uniplus-<amb>` | `kafka/ca` |
| `kafka/admin` | `uniplus-<amb>` e `plataforma-<amb>` | `kafka/admin` |
| `minio/root` | `uniplus-<amb>` e `plataforma-<amb>` | `minio/root` |
| `redis/default` | `uniplus-<amb>`, `geo-<amb>` e `plataforma-<amb>` | `redis` |
| `smtp/uniplus` | `uniplus-<amb>` e `plataforma-<amb>` | `smtp` |
| `postgres/geo` | `geo-<amb>` | `postgres` |
| `geo/encryption` | — | descartado: o Geo cifra pelo Transit (abaixo) |
| `postgres/apicurio` | `plataforma-<amb>` | `postgres/apicurio` |
| `postgres/keycloak` | `plataforma-<amb>` | `postgres/keycloak` |
| `keycloak/admin` | `plataforma-<amb>` | `keycloak/admin` |
| `keycloak/clients/kafka-ui` | `plataforma-<amb>` | `keycloak/kafka-ui` |
| `keycloak/clients/apicurio-registry` | `plataforma-<amb>` | `keycloak/apicurio-registry` |
| `keycloak/clients/grafana` | `plataforma-<amb>` | `keycloak/grafana` |
| `kafka-ui/jwt` | `plataforma-<amb>` | `kafka-ui/jwt` |
| `redis-ui/basic-auth` | `plataforma-<amb>` | `redis-ui/basic-auth` |
| `rabbitmq/admin` | `plataforma-<amb>` | `rabbitmq/admin` |
| `minio/loki` | `plataforma-<amb>` | `minio/loki` |
| `minio/tempo` | `plataforma-<amb>` | `minio/tempo` |
| `kes/server` | `plataforma-<amb>` | `kes/server` |
| `kes/identities` | `plataforma-<amb>` | `kes/identities` |
| `kes/api-keys` | `plataforma-<amb>` | `kes/api-keys` |
| keystore do KES (chaves mestras cifradas) | `plataforma-<amb>` | `kes-keystore/*` (prefixo exclusivo, em `kes.vault.kvPrefix`; KV em `kes.vault.kvEngine`) |
| `vault/root`, `vault-transit-bootstrap/token` | — | descartados (desenho antigo) |

## Transit (cifra)

Um mount Transit por sistema e ambiente. O mount genérico `transit/` deixa de existir. As chaves são AES-256-GCM, não exportáveis, sem backup em claro e com `deletion_allowed=false`; nunca se altera `min_decryption_version` nem se faz `trim`.

| Mount | Chaves | Quem usa | Operações |
|---|---|---|---|
| `uniplus-<amb>-transit` | `uniplus-selecao-identificadores-aesgcm`, `uniplus-selecao-sensiveis-aesgcm`, `uniplus-discentes-identificadores-aesgcm`, `uniplus-idempotency-aesgcm` | `uniplus-api-host` (namespace `uniplus`) | `encrypt`, `decrypt` |
| `uniplus-<amb>-transit` | `uniplus-selecao-identificadores-hmac`, `uniplus-selecao-sensiveis-hmac`, `instalacao-codigo` | `uniplus-api-host` | `hmac` (e `hmac/<chave>/<algoritmo>`) |
| `geo-<amb>-transit` | `geo-idempotency-aesgcm` | `unifesspa-geo-api` (namespace `geo`) | `encrypt`, `decrypt` |
| `plataforma-<amb>-transit` | `uniplus-kes-kek` | KES (namespace `kes`) | `encrypt`, `decrypt` |

Todas as operações são `update` sobre `<mount>/<operação>/<chave>`. O `uniplus-api-portal` não cifra (o `Program.cs` dele não registra a cifragem), então não tem role nem política. A `uniplus-kes-kek` mantém o nome porque protege arquivos já cifrados; onde ela já existe em outro mount, move-se com `vault secrets move transit plataforma-<amb>-transit`.

## Roles e políticas no Vault

`configurar-vault.sh` cria, para cada sistema `<s>` em `uniplus`, `geo` e `plataforma`:

- o KV v2 `<s>-<amb>`;
- a política `external-secrets-<s>`, com `read` em `<s>-<amb>/data/*` e `<s>-<amb>/metadata/*`;
- a role Kubernetes `external-secrets-<s>`, ligada à ServiceAccount `external-secrets-<s>` do namespace `external-secrets`.

Para cada API que cifra, `configurar-vault.sh` cria a política e a role Kubernetes de mesmo nome, ligada à ServiceAccount de mesmo nome e ao namespace dela, com `update` só nas operações da tabela acima: `uniplus-api-host` (`uniplus`) e `unifesspa-geo-api` (`geo`).

O KES usa a política e a role `kes` (criadas por `provisionar-verificacao.sh`), com acesso só a `plataforma-<amb>/data/kes-keystore/*` (não alcança `kes/server` nem `kes/api-keys`) e a `encrypt`/`decrypt` da `uniplus-kes-kek` em `plataforma-<amb>-transit`. O KV `secret/` e a política `external-secrets-read` do desenho anterior deixam de ser criados.
