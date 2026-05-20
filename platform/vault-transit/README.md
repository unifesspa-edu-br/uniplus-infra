# vault-transit

HashiCorp Vault dedicado em PA1 com engine Transit habilitada — provê auto-unseal cross-cluster aos Vaults de aplicação em SP1 e SP2.

## Propósito

Implementa a metade "central" da decisão do [ADR-007](../../docs/adrs/ADR-007-vault-ha-storage-unseal.md): um Vault dedicado em PA1 hospeda apenas a engine Transit, e os Vaults de aplicação em SP1/SP2 (ver [`platform/vault/`](../vault/)) consomem o endpoint Transit como mecanismo de auto-unseal.

A topologia é idêntica desde o lab até prod, variando apenas escala (1 réplica em lab/sanidade, 3 réplicas Raft em HML/prod).

## Upstream

- Chart: [hashicorp/vault](https://github.com/hashicorp/vault-helm)
- Versão pinada: `0.32.0` (Vault `1.21.2`)

A dependência é declarada com alias `vaultTransit` no `Chart.yaml` para que os values dos environments não conflitem com o chart `platform/vault/`, cujo alias padrão é `vault`.

## Dependências

- Cluster K3s em PA1 com label `uniplus.io/managed=true` reconhecida pelo ApplicationSet.
- StorageClass durável no cluster — definida via override por environment (ver sub-issue StorageClass).
- (Opcional, off por default) Prometheus operator (`#26`) para coleta via ServiceMonitor.
- (Opcional, off por default) Keycloak realm Uni+ (`apps/keycloak-replica/`) para OIDC do UI.

## Bootstrap

O Vault Transit precisa de bootstrap manual após o primeiro deploy em cada ambiente:

1. Init com Shamir 5/3.
2. Unseal manual com 3 dos 5 shares (distribuídos conforme procedimento institucional).
3. Habilitação da engine Transit + criação da chave `autounseal`.
4. Criação de policy + token periódico para os Vaults SP1/SP2 consumirem.

Procedimento detalhado em [`docs/RUNBOOKS.md` §1.4.A](../../docs/RUNBOOKS.md).

## Variáveis principais

| Caminho | Default | Descrição |
|---------|---------|-----------|
| `vaultTransit.server.ha.enabled` | `false` | HA Raft. Ligar em HML/prod via override. |
| `vaultTransit.server.ha.replicas` | `1` | Réplicas. `3` em HML/prod. |
| `vaultTransit.server.dataStorage.storageClass` | _(não definido)_ | StorageClass durável. Definir por environment. |
| `vaultTransit.server.resources` | `100m/256Mi → 500m/512Mi` | Tabela 10.1 do ARCHITECTURE.md. |
| `networkPolicy.allowedSourceCidrs` | `[]` | CIDRs dos clusters SP1/SP2 que podem chamar 8200/tcp. Obrigatório por environment. |
| `serviceMonitor.enabled` | `false` | Ligar quando #26 estiver pronto. |
| `ingress.enabled` | `false` | Ligar quando integração OIDC estiver pronta. |

## Observabilidade

Métricas internas do Vault expostas em `/v1/sys/metrics?format=prometheus`. Coleta via ServiceMonitor desligada por default — ligar via override quando o stack de Prometheus (#26) estiver disponível.

## Network

Tráfego 8200/tcp cross-cluster (SP1/SP2 → este Transit) faria parte do modelo 3-DC (ADR-007, superseded em 2026-05-19). No `standalone-compact` atual este chart não é deployado.

## Segurança

- Selado por Shamir 5/3 — sem auto-unseal externo (este Vault é o nó-raiz da cadeia de auto-unseal).
- Token de SP é periódico (renovação automática enquanto o Vault SP estiver vivo) e tem ACL restrita a `transit/encrypt/autounseal` e `transit/decrypt/autounseal`.
- Snapshot Raft diário para `pa1-backup` (ver [`docs/RUNBOOKS.md` §3.3](../../docs/RUNBOOKS.md)).
- Disaster recovery em [`docs/RUNBOOKS.md` §3.5](../../docs/RUNBOOKS.md).
