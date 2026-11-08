# vault

HashiCorp Vault de aplicação em HA Raft — gestão centralizada de secrets para os módulos do Uni+.

## Propósito

Cada cluster K3s hospeda o próprio Vault, com armazenamento Raft e unseal manual (chaves Shamir 5/3). O ArgoCD instala o chart; a inicialização e a abertura são manuais.

## Upstream

- Chart: [hashicorp/vault](https://github.com/hashicorp/vault-helm)
- Versão pinada: `0.32.0` (Vault `1.21.2`)

A dependência é declarada **sem alias** — values ficam sob `vault.*`.

## Dependências

- Cluster K3s com label `uniplus.io/managed=true`.
- StorageClass durável no cluster, definida via override por ambiente.
- (Opcional, desligado por padrão) Prometheus operator para coleta via ServiceMonitor.
- (Opcional, desligado por padrão) Traefik e Keycloak para IngressRoute da UI com OIDC.

## Bootstrap

Após o primeiro deploy em um cluster novo:

1. Inicializar o Vault com chaves Shamir 5/3.
2. Abrir o Vault em cada Pod.
3. Rodar `scripts/servicos-no-host/configurar-vault.sh` (KVs por sistema, políticas e roles do External Secrets).

Procedimento detalhado em [`docs/RUNBOOKS.md`](../../docs/RUNBOOKS.md).

## Variáveis principais

| Caminho | Default | Descrição |
|---------|---------|-----------|
| `vault.server.ha.enabled` | `true` | HA Raft. |
| `vault.server.ha.replicas` | `3` | Réplicas. Um nó só pode usar `1`. |
| `vault.server.ha.raft.config` | _(unseal manual)_ | String HCL completa; o ambiente pode substituí-la. |
| `vault.server.dataStorage.storageClass` | _(não definido)_ | StorageClass durável. Definir por ambiente. |
| `vault.server.resources` | `200m/256Mi → 500m/512Mi` | Elevar conforme a carga. |
| `vault.injector.enabled` | `true` | Vault Agent Injector. |
| `networkPolicy.appConsumerNamespaces` | `[]` | Namespaces que alcançam a API do Vault (login Kubernetes, Transit). |
| `serviceMonitor.enabled` | `false` | Ligar quando houver Prometheus. |
| `ingress.enabled` | `false` | Rota da UI; restringir à rede institucional e à VPN. |

## Observabilidade

Métricas internas do Vault expostas em `/v1/sys/metrics?format=prometheus`. Coleta via ServiceMonitor desligada por padrão.

## Segurança

- Unseal manual com chaves Shamir 5/3 geradas no init, sob custódia presencial.
- NetworkPolicy restringe o ingress a External Secrets, Traefik, consumidores listados e peers Raft; o egress fica restrito a DNS e API do Kubernetes.
