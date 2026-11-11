# ADR-014: Custódia do Vault por Shamir manual

- **Status:** ✅ Aceito
- **Data:** 2026-07-13 (reescrita para `uniplus-hml` e `uniplus-prd` em 2026-11-11)
- **Relacionado:** [Issue #439](https://github.com/unifesspa-edu-br/uniplus-infra/issues/439) · [Issue #786](https://github.com/unifesspa-edu-br/uniplus-infra/issues/786) · [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md) · [ADR-017](ADR-017-producao-aplicada-pelo-pipeline-na-vm-de-automacao.md)

## Contexto

O Vault de `uniplus-hml` e de `uniplus-prd` guarda as credenciais dos serviços de dados e as chaves
do Transit que cifram dados das aplicações. Ele precisa abrir (unseal) depois de cada reinício. As
VMs ficam na rede da Unifesspa, fora de qualquer provedor de nuvem, e não há Vault Transit nem KMS
de nuvem alcançável por elas.

## Decisão

1. **Shamir 5/3, manual.** O Vault é inicializado com cinco chaves e limiar três, nos dois
   ambientes. Cada reinício do pod o deixa selado até um operador informar três chaves com
   `vault operator unseal`, no prompt mascarado. O procedimento está em
   [RUNBOOKS](../RUNBOOKS.md#5-reinício-das-vms-e-abertura-do-vault).
2. **Cinco custodiantes distintos**, uma chave cada, fora do repositório. Ninguém guarda duas.
3. **Token raiz só para a configuração inicial** (`configurar-vault.sh`). As operações contínuas usam
   identidades com política própria, e o token raiz é revogado depois. Perder o conjunto de chaves
   (três ou mais perdidas) torna o Vault irrecuperável, então a troca de chaves (`vault operator
   rekey`) acontece quando um custodiante sai ou uma chave é comprometida.
4. **O snapshot do Raft é o backup.** O Shamir protege a abertura, não os dados. O snapshot é gerado
   fora das VMs e, em produção, antes de cada migration pelo pipeline de implantação, cifrado
   (ADR-017). Sem ele, a perda do disco perde o Vault e as chaves do Transit.

## Alternativas consideradas

- **Auto-unseal por Vault Transit dedicado:** exigiria outro Vault e conectividade que não existem.
  Rejeitada.
- **Auto-unseal por KMS de nuvem:** as VMs não estão em nuvem. Rejeitada.
- **Shamir 1/1:** deixa uma pessoa só com o poder de abrir o Vault. Rejeitada.

## Consequências

- Todo reinício do pod, da VM ou do K3s exige operador com três chaves; sem ele, as aplicações
  perdem o acesso aos segredos até a abertura.
- A revisão desta decisão só faz sentido se existir um Transit ou KMS alcançável pelas VMs.
