# Environment: prod-pa1

Valores específicos para o ambiente `prod-pa1` — cluster K3s no DC institucional UNIFESSPA (Marabá-PA), counterpart de produção do `lab-pa1`.

> Criado em 2026-05-03 pelo PR da issue #13 conforme [ADR-007](../../docs/adrs/ADR-007-vault-ha-storage-unseal.md). Configuração completa para o Vault Transit, mas **desligada por default** (`vaultTransit.enabled: false`) até as dependências de infraestrutura real (cert-manager, Traefik, StorageClass, DNS público, cluster K3s registrado no ArgoCD) estarem prontas.

## Componentes hospedados (alvo de produção)

**Dentro do K3s (gerenciados via Helm + ArgoCD):**

- **Vault Transit** — HA Raft 3 réplicas, auto-unseal cross-cluster para Vaults SP1/SP2 via DNS público `vault-transit.uniplus.unifesspa.edu.br`.

**Fora do K3s (a entrar em PRs futuros):**

- **Patroni quorum** (etcd) — quorum externo para PostgreSQL (#10).
- **Keycloak source institucional** — integração LDAP UNIFESSPA + federação Gov.br ([ADR-003](../../docs/adrs/ADR-003-govbr-federado-via-oidc-institucional.md)).
- **MinIO replica** — destino de bucket replication SP1/SP2 → PA1 (#12).
- **`backup-target`** — destino de backup PostgreSQL/MinIO/Vault (sub-issue de #13 para automação).

## Pré-requisitos para habilitar

1. Cluster K3s `prod-pa1` provisionado no DC UNIFESSPA e registrado no ArgoCD com label `uniplus.io/managed=true` e `environment=prod-pa1`.
2. cert-manager (#15) entregando certificado em Secret `vault-transit-tls`.
3. Traefik (#14) com IngressRoute apontando para o Service do Transit, e DNS `vault-transit.uniplus.unifesspa.edu.br` resolvendo para o Traefik.
4. StorageClass durável definida (sub-issue StorageClass).
5. CIDRs reais de SP1 e SP2 preenchidos em `networkPolicy.allowedSourceCidrs` (validados com a DIRSI conforme [`docs/network-matrix.md`](../../docs/network-matrix.md)).
6. Bootstrap manual do Vault Transit conforme [`docs/RUNBOOKS.md` §1.4.A](../../docs/RUNBOOKS.md): init Shamir 5/3, unseal manual, criação da engine Transit + chave + token periódico para SP1/SP2.

Quando todos os pré-requisitos estiverem prontos, trocar `vaultTransit.enabled: false` para `true` em PR dedicado (toca prod-* → exige 2 aprovações conforme política do projeto).

## Como usar

Este values é referenciado pelo ApplicationSet do ArgoCD em `argocd/applicationset.yaml`. Não execute `helm install` manualmente — deixe o ArgoCD gerenciar.

## Provisionamento

A infraestrutura física do datacenter institucional UNIFESSPA é responsabilidade da DIRSI. O cluster K3s `prod-pa1` será provisionado em coordenação com a DIRSI quando a fase de HML estiver concluída.
