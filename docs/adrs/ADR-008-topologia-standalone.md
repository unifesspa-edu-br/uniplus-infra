# ADR-008: Topologia `standalone` como modelo paralelo provider-agnostic

- **Status:** 🟡 Proposta
- **Data:** 2026-05-03
- **Relacionado:** [Issue #47](https://github.com/unifesspa-edu-br/uniplus-infra/issues/47) · [Epic #40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40)

## Contexto

O `uniplus-infra` modela exclusivamente a topologia **3 DCs lógicos** (`SP1` + `SP2` ativo-ativo + `PA1` institucional). Todo o `environments/`, `argocd/applicationset.yaml`, scripts, documentação e ADRs anteriores assumem essa topologia. Não existe variante para deploy em localidade única — nem como sanidade integrada, nem como fallback degradado.

Esse gap cria três problemas práticos:

1. **Validação integrada exige o lab inteiro montado.** Qualquer verificação end-to-end (OIDC, Vault, Postgres, Kafka, MinIO, observabilidade, ingress/TLS, apps Uni+) requer `SP1` + `SP2` + `PA1` simultâneos.
2. **Ausência de fallback operacional.** Se `SP1`/`SP2`/`PA1` estiverem indisponíveis (contrato EVEO ainda não fechado, manutenção institucional prolongada, incidente), não há como atender em emergência num provedor único.
3. **Sem ponto de entrada para validação OCI.** A OCI será o primeiro provider avaliado para complementar a infraestrutura. Sem um modelo monolocal, não é possível provisionar e validar a stack completa no OCI sem antes ter os 3 DCs configurados.

## Alternativas consideradas

1. **Estender `environments/lab-pa1/` para "lab-monolocal".** Reaproveitar o host `PA1` como cluster single-DC sem os peers `SP1`/`SP2`.
   - ❌ Rejeitada: confunde papéis. O `lab-pa1` simula o DC institucional Marabá, hospeda o Vault Transit (ADR-007) e serve de modelo de referência à DIRSI para regras de firewall/Palo Alto. Misturar "monolocal de sanidade" nele corromperia a fidelidade topológica do laboratório.

2. **Somente documentação, sem código novo.** Descrever como montar manualmente um ambiente single-DC a partir dos values existentes.
   - ❌ Rejeitada: não atende o requisito de fallback operacional nem a validação OCI. Sem `environments/standalone/` no GitOps, qualquer operador precisa criar overrides ad-hoc, quebrando o princípio de GitOps como única fonte de verdade (ADR-006).

3. **Cluster multi-nó com replicação intra-DC.** Criar `environments/standalone/` com Patroni multi-nó, Kafka KRaft 3 brokers + MinIO distribuído todos no mesmo DC.
   - ❌ Rejeitada: a topologia standalone é declaradamente single-point. Fingir HA no mesmo DC não valida resiliência real e aumenta o custo de infraestrutura sem ganho de fidelidade. O standalone documenta seus limites explicitamente.

4. **Topologia `standalone` como modelo paralelo separado.** Novo diretório `environments/standalone/` (GitOps, provider-agnostic) + `provisioning/<provider>/standalone/` (IaC, provider-specific). OCI como primeiro provider. Standalone coexiste com SP1/SP2/PA1 sem alterar esses ambientes.
   - ✅ Escolhida.

## Decisão

Introduzir **`standalone`** como modelo de topologia paralelo, com as seguintes premissas:

### O que muda

- **`environments/standalone/`** — overlay GitOps com values Helm para todos os charts existentes em `apps/` e `platform/`. Provider-agnostic: não contém OCIDs, ARNs ou qualquer referência a cloud específica. Overrides relevantes: `seal "ocikms"` (consumindo placeholder preenchido pelo provisioning), Postgres single-primary por banco, Keycloak sem federação Gov.br no MVP, observabilidade single-stack, `StorageClass: standalone-local-nvme`, ingress single-host.
- **`provisioning/oci/standalone/`** — código OpenTofu específico para OCI: VCN, subnets (pública para K8s + privada para data), NSGs, 2 instâncias Compute (k8s-host e data-host), Block Volumes, Reserved Public IP, registros DNS, OCI Vault KMS + Dynamic Group + IAM Policy para auto-unseal. State (`.tfstate`) **não vai para o Git** — inicialmente local, OCI Object Storage como evolução.
- **`scripts/bootstrap-standalone.sh`** — refator incremental de `bootstrap-lab.sh`, adicionando roles `standalone-k8s` e `standalone-data`. Roles existentes (`sp1`, `sp2`, `pa1`) continuam funcionando sem alteração.
- **`scripts/validate-standalone.sh`** — derivado de `validate-cluster.sh`, com checks específicos do modelo monolocal.

### O que não muda

- `argocd/applicationset.yaml` — o ApplicationSet já é genérico via label `environment: <env>`. Registrar o cluster com `uniplus.io/managed=true` + `environment=standalone` é suficiente para o GitOps reconciliar `environments/standalone/values.yaml` automaticamente. Nenhuma mudança estrutural.
- ADR-001 a ADR-007 — continuam válidos para a topologia 3-DC. Standalone opera fora do escopo de ADR-001 (1 cluster, não 3) e ADR-007 (Vault usa `seal "ocikms"` via OCI KMS, não Transit cross-cluster).

### Decisões de design já tomadas

| Ponto | Decisão |
|---|---|
| Layout Compute | 2 VMs separadas: `k8s-host` (K3s, subnet pública) e `data-host` (containers stateful via systemd, subnet privada) |
| Vault unseal | `seal "ocikms"` via OCI Vault KMS, autenticação por Resource Principal (Dynamic Group + IAM Policy); recovery keys Shamir 5/3 geradas no init e armazenadas **fora do repo** |
| OIDC MVP | Keycloak local 1 réplica, sem federação Gov.br; valida contrato OIDC/JWT entre frontends e APIs |
| Charts `data/*` | **Fora do escopo deste Epic** — gap pré-existente, tratado como Epic separado. O standalone documenta a dependência; validação end-to-end (Postgres/Kafka/MinIO) só após o Epic `data/*` aterrissar |
| `.tfstate` | Local no MVP; migração para OCI Object Storage com lock na fase de hardening |

### Quando usar standalone (e quando não usar)

**Usar para:** validação integrada antes de levar mudança ao lab 3-DC; demos; ambiente de aprendizado; fallback emergencial; canário de versão de chart.

**Não usar para:** validar HA geográfico, failover entre DCs, perda de PA1, replicação MinIO cross-site, consenso Patroni/Kafka KRaft cross-DC, atendimento de pico de edital com SLA (esse cenário exige a topologia 3-DC).

## Consequências

- ✅ **Validação integrada sem o lab 3-DC.** Mudanças nos charts podem ser validadas end-to-end no standalone antes de afetar o lab SP1/SP2/PA1.
- ✅ **Fallback operacional documentado.** Em indisponibilidade prolongada dos 3 DCs, existe procedimento formal para atender num provider único.
- ✅ **Caminho de entrada para OCI.** A OCI pode ser avaliada sem exigir provisionamento dos 3 DCs completos antes.
- ✅ **ApplicationSet sem mudança estrutural.** A generalização por label `environment` já implementada absorve o standalone automaticamente.
- ✅ **Fidelidade arquitetural preservada.** Standalone mantém ADR-002 (stateful fora do K8s), ADR-005 (containers via systemd), ADR-003 (Gov.br via OIDC, 1 réplica Keycloak), ADR-006 (GitOps via ArgoCD). Não simplifica a ponto de virar "ambiente diferente".
- ⚠️ **Não valida resiliência geográfica.** Standalone pode mascarar bugs de latência cross-DC, race conditions entre primaries Patroni distribuídos, particionamento Kafka KRaft cross-site. Standalone passa, prod 3-DC pode falhar — risco explicitamente documentado em `environments/standalone/README.md`.
- ⚠️ **Provider-specific confinado a `provisioning/`.** Nenhum OCID, ARN ou referência de provider pode entrar em `environments/standalone/`. Provider-specifics chegam via External Secrets ou parâmetros de bootstrap. Regra a ser fiscalizada em todo PR que toque standalone.
- ⚠️ **Vault init é operação manual única.** `vault operator init -recovery-shares=5 -recovery-threshold=3` é executado uma vez; recovery keys + root token armazenados fora do repo (gestor de senhas institucional ou cofre offline). Auto-unseal via OCI KMS dispensa intervenção em restarts subsequentes.
- ⚠️ **Charts `data/*` são pré-requisito para validação completa.** Standalone entrega GitOps + provisioning + bootstrap K8s completos; a matriz de validação (16 itens) só fecha 100% após o Epic `data/*` aterrissar.
