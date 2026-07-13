# ADR-014: Custódia do Vault via Shamir manual no `hml-standalone-single`

- **Status:** ✅ Aceito
- **Data:** 2026-07-13
- **Relacionado:** [Issue #439](https://github.com/unifesspa-edu-br/uniplus-infra/issues/439) · [Feature #435](https://github.com/unifesspa-edu-br/uniplus-infra/issues/435) · [Epic #434](https://github.com/unifesspa-edu-br/uniplus-infra/issues/434)

## Contexto

O `docs/RUNBOOKS.md §21.5` deixou deliberadamente em aberto a decisão de custódia do
Vault para o ambiente `hml-standalone-single` (VM real dedicada `192.168.21.134`, rede
interna UNIFESSPA, VPN-only): seguir o mesmo padrão Shamir manual do
`standalone-compact`, ou avaliar auto-unseal via Vault Transit. A Story #439 pede que
essa decisão seja tomada antes de criar o `environments/hml-standalone-single/values.yaml`.

O [ADR-007](ADR-007-vault-ha-storage-unseal.md) (Superseded) descrevia um Vault Transit
central em PA1 para auto-unseal de todos os clusters SP1/SP2 — mas esse desenho
dependia inteiramente do modelo de 3 DCs lógicos ([ADR-001](ADR-001-tres-dcs-logicos-e-clusters-k8s-independentes.md),
também Superseded). Não existe hoje nenhum Vault Transit provisionado e alcançável em
rede a partir de nenhum ambiente Uni+ — nem do `standalone-compact` (que já resolveu
essa mesma pergunta, ver abaixo), nem, com maior razão, da rede interna da UNIFESSPA
(isolada por VPN, sem rota para a VCN OCI onde rodaria um eventual Transit).

## Alternativas consideradas

1. **Auto-unseal via Vault Transit dedicado.** Provisionar (ou reaproveitar) um Vault
   Transit alcançável em rede a partir da VM HML, eliminando a necessidade de unseal
   manual após cada restart do Pod.
   - ❌ Rejeitada: não existe hoje nenhuma instância de Vault Transit provisionada em
     lugar algum do ecossistema Uni+ — provisionar uma só para este HML introduziria
     infraestrutura nova (outro Vault, outra rede a proteger, outro ponto de falha) e
     dependência de rede cross-ambiente (UNIFESSPA VPN-only → algum outro host) sem
     nenhum caminho de conectividade validado. Custo/risco desproporcional ao ganho
     (evitar `vault operator unseal` manual pós-restart, procedimento já documentado
     e operado em produção real).

2. **Auto-unseal via KMS de nuvem (OCI KMS, seguindo o desenho original de
   `standalone-compact`).** Delegar o unseal a uma chave gerenciada.
   - ❌ Rejeitada: não se aplica — a VM HML está na rede interna da própria
     UNIFESSPA, fora de qualquer provedor de nuvem. Mesmo se aplicável, o
     `standalone-compact` real já hoje **não** usa isso: bug confirmado
     (`go-kms-wrapping@v2.0.9`, nil pointer dereference em `ocikms.go:290`, ver
     `environments/standalone-compact/values.yaml`) forçou fallback para Shamir
     manual em produção real — reproduzir uma dependência já sabida como quebrada
     não faz sentido para um ambiente novo.

3. **Shamir manual, 1 réplica Raft — threshold igual ao `standalone-compact` (5
   shares/3), não ao `lab-standalone-single`.** O lab usa Shamir **1 share/1
   threshold** (`scripts/lab-standalone-single/bootstrap.sh`, `vault operator init
   -key-shares=1 -key-threshold=1`) — simplificação deliberada de ambiente
   descartável/single-operador (ver `docs/RUNBOOKS.md §20.5`), inadequada para um
   ambiente de homologação real com múltiplos operadores. `standalone-compact`
   (produção real) usa 5/3 (`docs/RUNBOOKS.md §8.4`) — esse é o padrão a seguir aqui.
   - ✅ Escolhida.

## Decisão

Adotar **Shamir manual, 5 shares/3 threshold, 1 réplica Raft** para o Vault do
`hml-standalone-single` — mesmo threshold de `environments/standalone-compact/values.yaml`
(produção real), **não** o 1/1 simplificado do `lab-standalone-single`. Réplica única
porque a topologia é host único (mesmo racional do lab). Após `vault operator init`,
cada restart do Pod (upgrade de K3s, manutenção da VM, OOMKill) exige unseal manual
com 3 das 5 shares — procedimento documentado em `docs/RUNBOOKS.md §8.4.2` (prompt
interativo mascarado nativo do `vault operator unseal`, sem stdin/argv — corrigido no
PR #461). A Story #442 (adaptação do script de bootstrap) precisa portar o
`vault operator init -key-shares=5 -key-threshold=3` de `standalone-compact` —
**não** copiar o `-key-shares=1 -key-threshold=1` do lab.

### Custódia das 5 shares

- **Distribuição:** cada uma das 5 shares vai para um custodiante institucional
  distinto (mesmo modelo de `standalone-compact`, gestor a definir na Story #445 —
  não necessariamente as mesmas 5 pessoas do `standalone-compact`, já que este é um
  ambiente HML, não produção). Nenhuma pessoa detém 2+ shares.
- **Root token:** gerado no `vault operator init`, usado só para a configuração
  inicial (policies, auth methods, KV mounts, e a policy/role `external-secrets`
  exigida pelo contrato do ClusterSecretStore em
  `environments/hml-standalone-single/values.yaml`). Antes de revogar o root
  token, criar uma identidade administrativa não-root (policy própria com
  permissão para gerenciar policies/auth methods/snapshots — não `sudo`
  irrestrito) para as operações contínuas (seed de secrets, rekey, snapshot
  manual). Só depois revogar o root token (`vault token revoke -self`) — sem
  essa identidade prévia, revogar o root token deixaria a VM sem nenhum
  caminho administrativo até o próximo `vault operator init`/rekey. Mesma
  prática recomendada para `standalone-compact`. Procedimento detalhado (nomes
  de policy, role) fica para a Story #445 documentar em `docs/RUNBOOKS.md`
  junto do primeiro `vault operator init` real.
- **Rekey:** se uma share for comprometida ou um custodiante sair do time,
  `vault operator rekey` gera um novo conjunto de 5 shares e invalida o anterior.
  Procedimento a documentar em `docs/RUNBOOKS.md` quando a Story #445 rodar o
  `vault operator init` de fato (não pode ser testado antes de existir um Vault
  real nesta VM).
- **Perda de share:** com threshold 3 de 5, perder até 2 shares não impede unseal.
  Perder 3+ shares torna os dados do Vault permanentemente irrecuperáveis (Shamir
  não tem "master key" de recuperação) — reforça a necessidade do backup abaixo.
- **Backup fora da VM:** Shamir protege o **unseal**, não substitui backup dos
  dados. Snapshot do Raft (`vault operator raft snapshot save`) precisa rodar
  periodicamente e ser armazenado fora desta VM (mesmo racional de
  `docs/RUNBOOKS.md §3.3` para `standalone-compact` — sem isso, perda de disco da
  VM é perda total do Vault, independente de quantas shares sobrevivam). Cadência e
  destino do snapshot ficam para a Story #445 definir junto do bootstrap real.
- **Teste de recuperação:** validar ao menos uma vez, após o `vault operator init`
  real (Story #445), que 3 das 5 shares de fato desselam o Vault — não presumir que
  o procedimento documentado funciona sem execução real contra a VM.

Revisitar a escolha de Shamir (não Transit) só se/quando existir um Vault Transit
real, provisionado e com conectividade de rede validada a partir da VM HML — não
antes.

## Consequências

- ✅ **Sem infraestrutura nova.** Nenhum Vault Transit adicional para provisionar,
  proteger e operar.
- ✅ **Procedimento já validado e documentado.** A equipe já opera esse fluxo em
  `standalone-compact`; `docs/RUNBOOKS.md §8.4.2` cobre o passo-a-passo, sem
  necessidade de escrever runbook novo.
- ✅ **Threshold consistente com produção real (`standalone-compact`).** 5/3 desde o
  primeiro `vault operator init` — evita ter que fazer `rekey` para sair do 1/1 do
  lab se este ambiente algum dia ganhar exigências mais próximas de produção.
- ⚠️ **Diverge deliberadamente do `lab-standalone-single`.** O lab usa 1/1
  (single-operador, ambiente descartável) — a Story #442 precisa portar o
  `-key-shares=5 -key-threshold=3` de `standalone-compact`, não copiar o comando do
  lab por padrão. Risco real de regressão se `bootstrap.sh` for adaptado por
  cópia superficial do lab sem revisar este ponto.
- ⚠️ **Unseal manual pós-restart.** Cada reinício do Pod do Vault exige operador
  humano com acesso a 3 das 5 shares (guardadas fora do repositório, distribuídas
  entre custodiantes distintos — ver seção "Custódia das 5 shares" acima) para
  rodar `vault operator unseal` 3 vezes. Aceitável para HML (sem SLA de
  disponibilidade contínua); reavaliar se este ambiente evoluir para produção real
  com exigência de restart automatizado sem intervenção.
- ⚠️ **Shamir protege o unseal, não os dados.** Sem snapshot Raft off-VM (ver
  acima), perda de disco da VM é perda total e irrecuperável do Vault — a
  distribuição de shares por si só não é backup.
