# Diretrizes do Repositório

> Arquivo lido por Codex/agentes genéricos. As mesmas regras aparecem em `CLAUDE.md` (Claude Code) e `GEMINI.md` (Gemini CLI).

## Estrutura do Projeto e Organização de Módulos

Repositório de IaC declarativa para o Uni+. Charts Helm de aplicação em `apps/`. Plataforma em `platform/` (Argo CD, Vault, External Secrets, KES, Traefik, observabilidade). Overrides do ambiente `uniplus-prd` em `environments/uniplus-prd/`. Bootstrap GitOps em `argocd/`. Scripts das VMs (serviços de dados fora do K8s) em `scripts/servicos-no-host/`. Docs em `docs/`.

## Comandos de Build, Teste e Desenvolvimento

- `make validate` — roda tudo (yaml/helm/markdown/shellcheck/schema-validate); mesmo que o CI executa.
- `make yaml-lint` — yamllint nos manifestos e values.
- `make helm-lint` — `helm lint` em `apps/*/` e `platform/*/`.
- `make shellcheck` — shellcheck nos scripts.
- `make markdown-lint` — markdownlint-cli2 nos `.md`.
- `make schema-validate` — valida `environments/uniplus-prd/values.yaml` contra os schemas dos charts.
- `./scripts/servicos-no-host/<script>.sh --dry-run` — preview antes de aplicar nas VMs.

## Estilo de Codificação e Convenções de Nomenclatura

YAML com indentação de 2 espaços. Nomes de recursos, branches, labels e charts em `kebab-case` (`uniplus-api-selecao`, nunca `uniplus_api_selecao`). Recursos Kubernetes devem trazer os labels `app.kubernetes.io/{name,instance,version,managed-by}` mais `app.kubernetes.io/part-of: uniplus`. Scripts em Bash com `set -euo pipefail`, sem vazar segredos em logs.

## Diretrizes de Teste

Sem suíte de unit tests de aplicação. Antes de abrir PR, rodar `make validate` localmente. Mudanças nos scripts de `servicos-no-host/` exigem `--dry-run` revisado e shellcheck limpo.

## Diretrizes de Commit e Pull Request

Conventional Commits em pt-BR (`feat(scope): ...`, `fix(scope): ...`, `docs(scope): ...`, `chore(scope): ...`). Subject em indicativo presente 3ª pessoa (`adiciona`, `corrige`, `remove`) — nunca infinitivo. Sem `Co-Authored-By`, sem `--no-verify` sem motivo explícito, sem commit direto na `main`. Abrir Issue antes de mudanças não-triviais. PRs devem descrever o que mudou, por quê, como foi testado, ambientes afetados, riscos e atualizações de docs. Detalhes em `CONTRIBUTING.md`.

## Dicas de Segurança e Configuração

Nunca commite credenciais, kubeconfigs, unseal keys, certificados, dumps ou configurações locais geradas. Use placeholders e mantenha secrets no Vault ou em arquivos locais ignorados via `.gitignore`. Vulnerabilidades em `SECURITY.md`, nunca em Issues públicas.
