# vault

HashiCorp Vault de aplicação em HA Raft (3 réplicas) por cluster SP1 e SP2 — gestão centralizada de secrets para os módulos do Uni+.

## Propósito

Implementa a metade de "aplicação" da decisão do [ADR-007](../../docs/adrs/ADR-007-vault-ha-storage-unseal.md): cada cluster K3s em SP1 e SP2 hospeda seu próprio Vault HA com 3 réplicas Raft, independentes entre si.

Auto-unseal cross-cluster via [`platform/vault-transit/`](../vault-transit/) em PA1.

A topologia é idêntica desde o lab até prod, variando apenas escala (recursos reduzidos em lab/sanidade, plenos em HML/prod).

## Upstream

- Chart: [hashicorp/vault](https://github.com/hashicorp/vault-helm)
- Versão pinada: `0.32.0` (Vault `1.21.2`)

A dependência é declarada **sem alias** — values ficam sob `vault.*`. Não conflita com `platform/vault-transit/` (alias `vaultTransit`).

## Dependências

- Cluster K3s em SP1 ou SP2 com label `uniplus.io/managed=true`.
- StorageClass durável no cluster — definida via override por environment (ver sub-issue StorageClass).
- Vault Transit em PA1 ([`platform/vault-transit/`](../vault-transit/)) já bootstrapped com a chave `autounseal` e token gerado para este cluster.
- Secret `vault-transit-token` no namespace do Vault (criado manualmente conforme RUNBOOKS §1.4.B; futura sub-issue pode automatizar via ExternalSecret).
- (Opcional, off por default) Prometheus operator (`#26`) para coleta via ServiceMonitor.
- (Opcional, off por default) Traefik (`#14`) e Keycloak realm Uni+ (`apps/keycloak-replica/`) para IngressRoute UI com OIDC.

## Bootstrap

Após o primeiro deploy em um cluster SP novo:

1. Criar Secret `vault-transit-token` com o token gerado no Transit em PA1.
2. Reiniciar o StatefulSet para reler a config de seal.
3. Init com Recovery Keys 5/3.
4. Validar `vault status` em cada Pod.

Procedimento detalhado em [`docs/RUNBOOKS.md` §1.4.B](../../docs/RUNBOOKS.md).

## Variáveis principais

| Caminho | Default | Descrição |
|---------|---------|-----------|
| `vault.server.ha.enabled` | `true` | HA Raft. Manter `true` em todas as fases (ADR-007). |
| `vault.server.ha.replicas` | `3` | Réplicas. Sempre 3 — topologia idêntica em todas as fases. |
| `vault.server.ha.raft.config` | _(sem seal Transit)_ | String HCL completa. Cada environment de SP1/SP2 substitui esta string para incluir `seal "transit"`. |
| `vault.server.dataStorage.storageClass` | _(não definido)_ | StorageClass durável. Definir por environment. |
| `vault.server.resources` | `200m/256Mi → 500m/512Mi` | Tabela 10.1 do ARCHITECTURE.md. Elevar em prod. |
| `vault.injector.enabled` | `true` | Vault Agent Injector. |
| `networkPolicy.transitEndpointCidrs` | `[]` | CIDRs do cluster PA1 onde o Transit roda. Definir por environment. |
| `serviceMonitor.enabled` | `false` | Ligar quando #26 estiver pronto. |
| `ingress.enabled` | `false` | Ligar quando integração OIDC estiver pronta. |

## Observabilidade

Métricas internas do Vault expostas em `/v1/sys/metrics?format=prometheus`. Coleta via ServiceMonitor desligada por default — ligar via override quando o stack de Prometheus (#26) estiver disponível.

## Network

Tráfego cross-cluster (este Vault → Vault Transit em PA1, 8200/tcp) precisa ser liberado pela DIRSI antes da promoção a sanidade. Linhas correspondentes documentadas em [`docs/network-matrix.md`](../../docs/network-matrix.md).

## Segurança

- Auto-unseal Transit (sem chaves Shamir presenciais para reinício automático).
- Recovery keys 5/3 geradas no init — única saída em cenário catastrófico (perda do Transit em PA1 + perda do snapshot do Transit). Ver [`docs/RUNBOOKS.md` §3.5.D](../../docs/RUNBOOKS.md).
- Snapshot Raft diário para `pa1-backup` (ver [`docs/RUNBOOKS.md` §3.3](../../docs/RUNBOOKS.md)).
- NetworkPolicy restringe ingress a external-secrets, Traefik e peers Raft; egress restrito a Transit em PA1 + DNS + K8s API.
