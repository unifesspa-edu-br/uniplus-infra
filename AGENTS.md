# Repository Guidelines

## Project Structure & Module Organization

This repository stores the declarative infrastructure for Uni+. Application Helm charts live in `apps/` (`uniplus-web`, `uniplus-api-*`, `clamav-scanner`, `keycloak-replica`). Platform services live in `platform/`, including Argo CD, Vault, External Secrets, Traefik, cert-manager, Cloudflare Tunnel, and observability components. Stateful host-managed services are documented under `data/` (`postgres`, `kafka`, `minio`, `redis`). Environment-specific overrides live in `environments/lab-*` and `environments/prod-*`. GitOps bootstrap manifests are in `argocd/`, operational docs are in `docs/`, and lab automation scripts are in `scripts/`.

## Build, Test, and Development Commands

- `yamllint apps/ platform/ data/ environments/ argocd/`: validates YAML style for manifests and values files.
- `for chart in apps/*/ platform/*/; do [ -f "$chart/Chart.yaml" ] && helm lint "$chart"; done`: lints all Helm charts that contain `Chart.yaml`.
- `shellcheck scripts/*.sh`: checks shell scripts for portability and common bugs.
- `markdownlint-cli2 '**/*.md'`: validates Markdown documentation.
- `./scripts/bootstrap-lab.sh --role=sp1 --dry-run`: previews lab provisioning without changing the host.
- `./scripts/validate-cluster.sh`: checks Docker, Helm, Kubernetes, Argo CD, host services, and connectivity after bootstrap.

## Coding Style & Naming Conventions

Use 2-space indentation for YAML and Helm values. Resource names, branches, labels, and chart names should use `kebab-case`, for example `uniplus-api-selecao`. Kubernetes resources should include standard `app.kubernetes.io/*` labels and `app.kubernetes.io/part-of: uniplus`. Shell scripts must use Bash, keep `set -u`/`pipefail` style safeguards where practical, and avoid leaking secrets in logs.

## Testing Guidelines

There is no application unit test suite in this repository. Validation is configuration-focused: run YAML lint, Helm lint, ShellCheck, Markdown lint, and lab checks before opening a PR. For changes under `environments/prod-*`, document the lab environment used and the rollback path.

## Commit & Pull Request Guidelines

Use Conventional Commits, matching existing history and `CONTRIBUTING.md`: `feat(scope): ...`, `fix(scope): ...`, `docs(scope): ...`, or `chore(scope): ...`. Open an Issue before non-trivial changes. PRs must describe what changed, why, how it was tested, affected environments, risks, and documentation updates. Production changes require extra reviewer attention.

## Security & Configuration Tips

Never commit credentials, kubeconfigs, unseal keys, Cloudflare tokens, certificates, dumps, or generated local config. Use placeholders in documentation and keep real secrets in Vault or local-only files ignored by `.gitignore`. Report vulnerabilities privately through `SECURITY.md`, not public Issues.
