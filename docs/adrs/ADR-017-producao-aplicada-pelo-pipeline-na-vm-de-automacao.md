# ADR-017: Produção aplicada pelo pipeline na VM de automação

- **Status:** ✅ Aceito
- **Data:** 2026-11-11
- **Issue:** [#779](https://github.com/unifesspa-edu-br/uniplus-infra/issues/779)
- **Relacionado:** substitui, na [ADR-016](ADR-016-producao-le-o-repositorio-de-implantacao.md), a decisão do sync manual

## Contexto

A ADR-016 manteve o sync de produção manual, no ArgoCD, porque não havia runner dedicado à produção.
Com isso, o backup antes da migration e a conferência depois do sync dependiam de quem operava. A VM
`uniplus-prod-automacao` passou a hospedar o runner `uniplus-prd` (#776), separada das VMs de
aplicação e de dados.

## Decisão

Produção é aplicada pelo pipeline do repositório de implantação, no runner `uniplus-prd`.

- **Dois botões:** um por componente para preparar, outro para aplicar. O preparo continua como na
  ADR-016: confere homologação e grava em `prd/`. O botão de aplicar é manual, liberado só depois
  do preparo no mesmo pipeline. Ele:
  - recusa aplicar se `prd/` mudou depois do preparo;
  - sincroniza só as Applications do componente;
  - espera a saúde, confere o digest em execução e roda a fumaça.
- **Backup antes da migration:** antes do sync de um componente com migration, o botão faz o
  backup do PostgreSQL, com role sem escrita nas tabelas das aplicações, aceito só da VM de
  automação, e o snapshot do Vault, com AppRole que só lê o snapshot. Os dois saem cifrados com as chaves públicas OpenPGP do
  repositório de implantação e ficam como artefato do job. O sync não roda sem o backup.
- **Credenciais:** as de produção ficam em variáveis protegidas do GitLab, restritas ao ambiente
  dos botões de aplicar. A conta do pipeline no ArgoCD de produção só lê e sincroniza as
  Applications dos componentes.

Continuam valendo: nenhum sync automático no ArgoCD e mudança de charts ou de values por merge
request revisado.

## Alternativas consideradas

- **Manter o sync manual:** rejeitada. Backup, ordem e conferência dependiam de quem operava.
- **Aplicar no mesmo botão do preparo:** rejeitada. Separar os botões permite revisar o diff
  antes de aplicar.
- **Runner nas VMs de produção:** rejeitada. Um job comprometido teria acesso direto ao cluster e
  aos dados.

## Consequências

- O PostgreSQL passa a aceitar a VM de automação, só na porta 5432 e só para o role de backup. O
  role lê todos os dados, inclusive os verificadores SCRAM de `pg_authid`. É aceito porque as
  senhas dos roles são aleatórias de 256 bits e o role já lê todos os dados das aplicações.
- Reverter uma versão continua manual: merge request em `prd/` e sync no ArgoCD.
- Restaurar um backup exige a chave privada OpenPGP do sistema, guardada fora das VMs.
- A VM de automação alcança a rede de produção. Por isso o runner só aceita jobs de branch
  protegida.
