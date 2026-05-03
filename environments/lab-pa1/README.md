# Environment: lab-pa1

Valores específicos para o ambiente `lab-pa1` — cluster K3s no host i7 (Ubuntu) simulando o DC institucional UNIFESSPA (PA1).

> **Renomeado de `lab-witness` em 2026-05-03 (issue #13).** Antes deste PR, o ambiente era apenas um host com containers Docker isolados (etcd witness, keycloak-master, minio-master, backup-target). Foi promovido a cluster K3s real para hospedar o Vault Transit e exercitar a topologia cross-cluster do [ADR-007](../../docs/adrs/ADR-007-vault-ha-storage-unseal.md) já no laboratório.

## Componentes hospedados

**Dentro do K3s (gerenciados via Helm + ArgoCD):**

- **Vault Transit** ([`platform/vault-transit/`](../../platform/vault-transit/)) — auto-unseal cross-cluster para Vaults de aplicação em SP1 e SP2.

**Fora do K3s (containers Docker isolados, gerenciados pelo `bootstrap-lab.sh`):**

- **`pa1-consensus-witness`** (etcd) — quorum externo opcional para Patroni.
- **Keycloak Master** (`start-dev`) — fonte OIDC institucional simulada (LDAP federation futura).
- **MinIO Master** — replica de objetos + backup target.
- **`backup-target`** — destino de backup PostgreSQL/MinIO/Vault, retenção 4 semanas full + 7 dias incremental.

## Como usar

Este values é referenciado pelo ApplicationSet do ArgoCD em `argocd/applicationset.yaml` para gerar Applications no cluster `lab-pa1`. Cluster precisa ter sido registrado com `argocd cluster add` aplicando label `uniplus.io/managed=true` e `environment=lab-pa1`.

Não execute `helm install` manualmente neste values — deixe o ArgoCD gerenciar.

## Rede

- Cluster K3s exposto via label `uniplus.io/managed=true`.
- Containers fora do K8s ficam na bridge Docker `172.30.0.0/16` para isolamento.
- Comunicação cross-cluster: Vaults SP1/SP2 chamam o Vault Transit aqui via 8200/tcp — ver [`docs/network-matrix.md`](../../docs/network-matrix.md).

## Provisionamento

Veja [`docs/SETUP.md`](../../docs/SETUP.md) e o script `scripts/bootstrap-lab.sh --role=pa1`.
