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
| Vault PVC | `kubectl delete pvc data-<release>-vault-0` destrói o estado Raft sem peer para recuperar — single-replica, único ambiente onde isso é destrutivo sem aviso (em SP1/SP2, 2 das 3 réplicas sobrevivem) |
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

## Pré-requisitos não-implementados

Charts referenciados pelo overlay que ainda são placeholders (sem `Chart.yaml`/templates) e precisam aterrissar antes do bootstrap funcionar end-to-end:

- `platform/cert-manager/` — `ingress.tls.issuer: letsencrypt` neste overlay assume `cert-manager` instalado e um `ClusterIssuer` chamado `letsencrypt` configurado para HTTP-01 (issue #15).
- `platform/traefik/` — terminação TLS e roteamento por path no FQDN único de standalone.
- `platform/external-secrets/` — sintetiza o Secret `vault-ocikms-config` consumido pelo Vault (issue #64).
- `platform/cloudflared/`, `platform/observability/*` — completam o stack de borda e observabilidade.

Standalone entrega o overlay GitOps; os charts acima são gap pré-existente do repositório, não bloqueio específico desta topologia.

## Charts `data/*` — fora do escopo

Standalone entrega GitOps + provisioning + bootstrap K8s completos. A matriz de validação end-to-end (Postgres, Kafka, MinIO no data-host) só fecha 100% após o Epic `data/*` aterrissar — gap pré-existente, tratado como Epic separado (ADR-008, seção "Decisões de design já tomadas").

## Matriz observada de reconciliação ArgoCD

Resultado da validação executada em 2026-05-05 contra o cluster `uniplus-standalone` (issue #86), aplicando `argocd/project.yaml` + `argocd/applicationset.yaml` após registrar o cluster com labels `uniplus.io/managed=true` + `environment=standalone`. Esta seção é o "estado da arte" que o standalone entrega hoje — fixa a expectativa de quem registra um novo cluster e impede falsos positivos em futuras sessões de validação.

| Application | Sync | Health | Diagnóstico |
|---|---|---|---|
| `platform-storage-uniplus-standalone` | Synced | Healthy | StorageClass `standalone-local-nvme` criada e em uso pelos PVCs do Vault. |
| `platform-vault-uniplus-standalone` | Synced | Progressing | Recursos aterrissam (StatefulSet, Services, RBAC, NetworkPolicy, Webhook). PVCs Bound. Pod-0 fica em `CreateContainerConfigError` com `Error: secret "vault-ocikms-config" not found` — comportamento esperado até que **#64** (Vault init + auto-unseal OCI KMS) sintetize o Secret via External Secrets. |
| `platform-vault-transit-uniplus-standalone` | Synced | Healthy | `vaultTransit.enabled: false` no overlay → render vazio. Correto: standalone usa OCI KMS, não Transit em PA1. |
| `platform-cert-manager-uniplus-standalone` | Unknown | Healthy | Chart placeholder sem `Chart.yaml` (gap pré-existente — issue #15). `ComparisonError`: `no such file or directory ... platform/cert-manager/Chart.yaml`. |
| `platform-traefik-uniplus-standalone` | Unknown | Healthy | Idem placeholder. |
| `platform-external-secrets-uniplus-standalone` | Unknown | Healthy | Idem placeholder — bloqueia #64 (sem ESO não há como sintetizar `vault-ocikms-config`). |
| `platform-cloudflared-uniplus-standalone` | Unknown | Healthy | Idem placeholder. |
| `platform-observability-{prometheus,grafana,loki,tempo,otel-collector}-uniplus-standalone` | Unknown | Healthy | Idem placeholder. |
| `uniplus-web-uniplus-standalone` | Synced | Healthy | Chart sem templates → render vazio. "Healthy" reflete zero recursos, não app rodando. |
| `uniplus-api-{portal,selecao,ingresso}-uniplus-standalone` | Synced | Healthy | Idem render vazio. Endpoints de Postgres/Redis/Kafka/MinIO chegariam via External Secrets a partir do data-host quando o Epic `data/*` aterrissar. |
| `clamav-scanner-uniplus-standalone` | Synced | Healthy | Idem render vazio. |
| `keycloak-replica-uniplus-standalone` | Synced | Healthy | Idem render vazio. |

**Ajustes de values descobertos:** nenhum específico ao overlay standalone. O `values.yaml` deste diretório cobre os charts reais (`platform/storage`, `platform/vault`, `platform/vault-transit`) sem necessidade de override adicional.

**Bug corrigido na validação:** os dois ApplicationSets em `argocd/applicationset.yaml` precisavam de `spec.goTemplate: true` + `goTemplateOptions: [missingkey=error]` — sem isso o controller renderizava `{{.app}}`, `{{.metadata.labels.environment}}` e `{{.component | replace "/" "-"}}` literalmente, todos os Applications colidiam no mesmo nome e o AppSet falhava em `ApplicationValidationError`. O fix está no manifesto principal e não é específico do standalone (afeta qualquer ambiente).

## Documentos relacionados

- [ADR-008 — Topologia standalone](../../docs/adrs/ADR-008-topologia-standalone.md) — decisão e premissas
- [docs/RUNBOOKS.md §8](../../docs/RUNBOOKS.md) — bootstrap e teardown
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — visão arquitetural geral
- Epic [#40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40) — execução da topologia standalone
