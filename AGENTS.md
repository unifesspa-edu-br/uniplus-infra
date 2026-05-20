# Diretrizes do Repositório

> Arquivo lido por Codex/agentes genéricos. As mesmas regras aparecem em `CLAUDE.md` (Claude Code) e `GEMINI.md` (Gemini CLI). A visão de produto vem do monorepo:

@docs/visao-do-projeto.md

## Estrutura do Projeto e Organização de Módulos

Repositório de IaC declarativa para o Uni+. Charts Helm de aplicação em `apps/` (`uniplus-web`, `uniplus-api-*`, `clamav-scanner`, `keycloak-replica`, `apicurio-registry`, `kafka-ui`, `redis-ui`). Plataforma em `platform/` (Argo CD, Vault, External Secrets, Traefik, cert-manager, observabilidade). Stateful no host (Postgres, Kafka, MinIO, Redis) documentado em `data/`. Overrides do único ambiente vivo em `environments/standalone-compact/`. Bootstrap GitOps em `argocd/`. Provisionamento OpenTofu em `provisioning/oci/standalone-compact/`. Scripts em `scripts/`. Docs em `docs/`.

O modelo aspiracional dos 3 DCs (SP1+SP2+PA1) está em `docs/ARCHITECTURE.md §5.5` como referência futura — ADRs 001/007 estão marcados como Superseded.

## Comandos de Build, Teste e Desenvolvimento

- `make validate` — roda tudo (yaml/helm/markdown/shellcheck/schema-validate); mesmo que o CI executa.
- `make yaml-lint` — yamllint nos manifestos e values.
- `make helm-lint` — `helm lint` em `apps/*/` e `platform/*/`.
- `make shellcheck` — shellcheck em `scripts/*.sh`.
- `make markdown-lint` — markdownlint-cli2 nos `.md`.
- `make schema-validate` — valida `environments/standalone-compact/values.yaml` contra os schemas dos charts.
- `./scripts/bootstrap-standalone.sh --role=standalone-{k8s,data} --dry-run` — preview do bootstrap antes de aplicar.
- `./scripts/validate-standalone.sh` — smoke pós-bootstrap do k8s-host + data-host.

## Estilo de Codificação e Convenções de Nomenclatura

YAML com indentação de 2 espaços. Nomes de recursos, branches, labels e charts em `kebab-case` (`uniplus-api-selecao`, nunca `uniplus_api_selecao`). Recursos Kubernetes devem trazer os labels `app.kubernetes.io/{name,instance,version,managed-by}` mais `app.kubernetes.io/part-of: uniplus`. Scripts em Bash com `set -euo pipefail`, sem vazar segredos em logs.

## Diretrizes de Teste

Sem suíte de unit tests de aplicação. Antes de abrir PR, rodar `make validate` localmente. Mudanças no `bootstrap-standalone.sh` exigem `--dry-run` revisado. Após apply real, executar `validate-standalone.sh` e os `smoke-*.sh` pertinentes.

## Diretrizes de Commit e Pull Request

Conventional Commits em pt-BR (`feat(scope): ...`, `fix(scope): ...`, `docs(scope): ...`, `chore(scope): ...`). Subject em indicativo presente 3ª pessoa (`adiciona`, `corrige`, `remove`) — nunca infinitivo. Sem `Co-Authored-By`, sem `--no-verify` sem motivo explícito, sem commit direto na `main`. Abrir Issue antes de mudanças não-triviais. PRs devem descrever o que mudou, por quê, como foi testado, ambientes afetados, riscos e atualizações de docs. Detalhes em `CONTRIBUTING.md`.

## Dicas de Segurança e Configuração

Nunca commite credenciais, kubeconfigs, unseal keys, certificados, dumps ou configurações locais geradas. Use placeholders e mantenha secrets no Vault ou em arquivos locais ignorados via `.gitignore`. Vulnerabilidades em `SECURITY.md`, nunca em Issues públicas.
