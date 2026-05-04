# Environment: standalone

Topologia paralela, provider-agnostic, single-DC e single-host. Decisão formalizada na [ADR-008](../../docs/adrs/ADR-008-topologia-standalone.md) e implementada na [Epic #40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40).

Este overlay GitOps coexiste com `lab-{sp1,sp2,pa1}` e `prod-{sp1,sp2,pa1}` sem alterá-los — mantém a fidelidade arquitetural do modelo 3-DC e adiciona um modelo monolocal para validação integrada, demos e fallback emergencial.

## Topologia em uma frase

Um cluster K3s em um host (`k8s-host`) + um host externo para componentes stateful (`data-host`) gerenciados por systemd (Postgres, Kafka, MinIO, Redis). Vault HA Raft com 1 réplica, auto-unseal via KMS do provider. Sem peers `SP2`/`PA1`.

## Quando usar

- ✅ Validação integrada antes de levar mudança ao lab 3-DC
- ✅ Demonstrações para stakeholders
- ✅ Ambiente de aprendizado para novos contribuidores
- ✅ Fallback operacional em indisponibilidade prolongada dos 3 DCs
- ✅ Canário de versão de chart antes de promover para `lab-*`

## Quando **não** usar

- ❌ Validar HA geográfico ou failover entre DCs
- ❌ Validar perda de PA1 ou replicação MinIO cross-site
- ❌ Validar consenso Patroni / Kafka KRaft cross-DC
- ❌ Atendimento de pico de edital com SLA — esse cenário exige 3-DC

## Limitações conhecidas

| Aspecto | Limitação |
|---|---|
| Resiliência | Single-host: queda da VM derruba toda a plataforma |
| Postgres | Single-primary por banco (sem replica, sem Patroni) |
| Vault | 1 réplica Raft (StatefulSet 3-réplica ficaria Pending no single-node) |
| Vault keys | Re-init pós-teardown re-gera Shamir 5/3 — standalone não é cofre durável |
| Keycloak | Sem federação Gov.br no MVP — apenas validação OIDC/JWT local |
| Storage | `reclaimPolicy: Delete` — re-bootstrap via Tofu apaga PVs |
| Observabilidade | Stack único (Prometheus/Loki/Tempo single-replica), retenção curta |
| Performance | Não modela latência cross-DC — race conditions geográficas ficam invisíveis aqui |

> **Risco a fiscalizar em revisão:** standalone passar e prod 3-DC falhar é um modo conhecido. Bugs sensíveis a partição de rede e latência cross-site **não** são detectáveis aqui.

## Provider-specifics

Por regra (ADR-008), nada provider-specific entra neste diretório:

- ❌ OCIDs, ARNs, project IDs
- ❌ Endpoints concretos de cloud (KMS, IAM, IMDS)
- ❌ Credenciais ou tokens
- ✅ Apenas o **nome do mecanismo** de unseal (`seal "ocikms"`, `seal "awskms"`, `seal "azurekeyvault"`, …)

Identificadores e endpoints chegam ao Pod do Vault via env vars injetados a partir do Secret `vault-ocikms-config`, sintetizado por External Secrets a partir do cofre do provider (sub-issue #64).

Para usar outro provider:

1. Substituir o bloco `seal "ocikms"` em `vault.server.ha.raft.config` pelo seal apropriado.
2. Ajustar `extraSecretEnvironmentVars` para os env vars exigidos pelo seal escolhido.
3. Provisionar o KMS + Dynamic Group + Policy correspondente em `provisioning/<provider>/standalone/` (Tofu).

Tudo o mais (Postgres single-primary, Keycloak sem Gov.br, observabilidade single-stack, `StorageClass: standalone-local-nvme`, ingress single-host) é universal.

## Como o ApplicationSet aplica

`argocd/applicationset.yaml` é genérico via label `environment: <env>`. Para o ArgoCD reconciliar este overlay basta registrar o cluster com:

```bash
argocd cluster add <kube-context> \
  --name uniplus-standalone \
  --label uniplus.io/managed=true \
  --label environment=standalone
```

Procedimento detalhado: `docs/RUNBOOKS.md` §8 (Bootstrap e Teardown — Ambiente Standalone OCI).

## Pré-requisitos de bootstrap

1. Provisionamento OCI (manual via CLI hoje; codificação Tofu é trabalho da Story #75 → #80 da Epic #40).
2. `./scripts/bootstrap-standalone.sh --role=standalone-k8s` no `k8s-host`.
3. `./scripts/bootstrap-standalone.sh --role=standalone-data` no `data-host`.
4. `./scripts/validate-standalone.sh` para checagem de sanidade.
5. Registrar cluster no ArgoCD conforme acima.
6. Vault init + verificação de auto-unseal (ver `docs/RUNBOOKS.md` §8.4).

## Charts `data/*` — fora do escopo

Standalone entrega GitOps + provisioning + bootstrap K8s completos. A matriz de validação end-to-end (Postgres, Kafka, MinIO no data-host) só fecha 100% após o Epic `data/*` aterrissar — gap pré-existente, tratado como Epic separado (ADR-008, seção "Decisões de design já tomadas").

## Documentos relacionados

- [ADR-008 — Topologia standalone](../../docs/adrs/ADR-008-topologia-standalone.md) — decisão e premissas
- [docs/RUNBOOKS.md §8](../../docs/RUNBOOKS.md) — bootstrap e teardown
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — visão arquitetural geral
- Epic [#40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40) — execução da topologia standalone
