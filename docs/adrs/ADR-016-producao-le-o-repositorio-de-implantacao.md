# ADR-016: Produção lê o repositório de implantação

- **Status:** ✅ Aceito (sync manual substituído pela [ADR-017](ADR-017-producao-aplicada-pelo-pipeline-na-vm-de-automacao.md))
- **Data:** 2026-11-09
- **Relacionado:** [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md) · [ADR-006](ADR-006-gitops-com-argocd.md)

## Contexto

A ADR-015, item 3, previa a atualização da produção por tag deste repositório, o label
`uniplus.io/revision` no cluster e um script que o gravava. Cada versão exigia um pull request aqui
e os values de produção ficavam duplicados em relação aos da homologação.

## Decisão

A produção lê versões e values do repositório de implantação (GitLab institucional), como a
homologação. A versão é promovida por um botão do pipeline, que só grava em `prd/` o que já roda em
homologação, conferido pelo digest de cada pod. O sync é manual, por Maintainer, sem `automated`, e os
ApplicationSets nunca apagam Applications.

## Alternativas consideradas

- **Pull request neste repositório a cada versão:** rejeitada pelo líder técnico.
- **Sync de produção pelo pipeline:** rejeitada. O sync é um ato deliberado, e não há runner
  dedicado em produção.

## Consequências

- Os values de produção saem deste repositório; `environments/uniplus-prd/` fica só como base de
  validação dos charts no CI.
- Uma tag movida no GHCR é coberta pelo campo digest dos charts (#770).
- O bootstrap deixa o cluster registrado e orienta a aplicar a Application raiz do repositório de
  implantação.
