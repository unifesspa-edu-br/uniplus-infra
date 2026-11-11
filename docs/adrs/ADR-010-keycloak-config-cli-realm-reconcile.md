# ADR-010: Reconciliação do realm do Keycloak via keycloak-config-cli

- **Status:** ✅ Aceito
- **Data:** 2026-05-10 (reescrita para `uniplus-hml` e `uniplus-prd` em 2026-11-11)
- **Relacionado:** [Issue #177](https://github.com/unifesspa-edu-br/uniplus-infra/issues/177) · [Issue #786](https://github.com/unifesspa-edu-br/uniplus-infra/issues/786) · [ADR-016](ADR-016-producao-le-o-repositorio-de-implantacao.md)

## Contexto

O chart `apps/keycloak-replica/` entrega o realm `uniplus` a partir de
`apps/keycloak-replica/files/uniplus-realm.json`, importado com `--import-realm`. O Keycloak 26.x
ignora o import quando o realm já existe, então mudanças posteriores no arquivo (clients,
protocolMappers, roles, scopes) não chegam ao realm vivo. Corrigir à mão com `kcadm.sh` deixa o
Git e o realm divergirem sem aviso.

## Decisão

O realm é reconciliado por um **Job Helm hook `post-install,post-upgrade`** que roda o
`keycloak-config-cli` (adorsys), do chart `apps/keycloak-replica/`, a partir do mesmo
`uniplus-realm.json`. O Git é a fonte do estado do realm.

- **Opt-in onde o chart implanta o Keycloak:** `keycloak.realmReconcile.enabled`, desligado por
  padrão, só tem efeito com `keycloak.enabled`. `uniplus-prd` usa o Keycloak institucional e não o
  implanta, então o Job não se aplica ali; quem liga é o ambiente que implanta o chart, pelos
  próprios values.
- **Reconcilia clients por completo e preserva o resto:** clients e seus recursos de autorização
  em `full` (o Git manda, inclusive removendo o que não está no arquivo); usuários, grupos, roles,
  escopos, componentes, fluxos de autenticação e ações obrigatórias em `no-delete`, de modo que o
  que foi criado fora do arquivo sobrevive.
- **Segredos por variável de ambiente:** o arquivo referencia os segredos por variável, que o Job
  recebe dos Secrets do chart, preenchidos pelo External Secrets a partir do Vault.
- **Espera o Keycloak** antes de reconciliar e falha visível no ArgoCD se não conseguir.
- **Imagem do CLI** fixada em `keycloak.realmReconcile.image.tag`, escolhida entre as publicadas
  pelo adorsys e validada contra o Keycloak em uso.

## Alternativas consideradas

- **Init container com `kcadm.sh`:** roda a cada reinício do pod e depende do próprio Keycloak
  estar no ar. Rejeitada.
- **Job com script `kcadm.sh` próprio:** sem reconciliação por diferença, exigiria script grande e
  frágil. Rejeitada.
- **Ferramenta própria em Go:** custo de manutenção sem ganho. Rejeitada.

## Consequências

- Mudança no `realm.json` chega ao realm vivo depois do sync, por merge request revisado.
- Uma imagem a mais para manter e validar a cada atualização do Keycloak.
- O Job é idempotente e pode rodar a cada `helm upgrade`.
