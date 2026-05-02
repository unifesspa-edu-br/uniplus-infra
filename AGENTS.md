# Diretrizes do Repositório

## Estrutura do Projeto e Organização de Módulos

Este repositório armazena a infraestrutura declarativa para o Uni+. Os charts Helm de aplicação vivem em `apps/` (`uniplus-web`, `uniplus-api-*`, `clamav-scanner`, `keycloak-replica`). Os serviços de plataforma vivem em `platform/`, incluindo Argo CD, Vault, External Secrets, Traefik, cert-manager, Cloudflare Tunnel e componentes de observabilidade. Os serviços stateful gerenciados no host estão documentados em `data/` (`postgres`, `kafka`, `minio`, `redis`). Overrides específicos por ambiente vivem em `environments/lab-*` e `environments/prod-*`. Os manifestos de bootstrap do GitOps estão em `argocd/`, documentos operacionais em `docs/` e scripts de automação de laboratório em `scripts/`.

## Comandos de Build, Teste e Desenvolvimento

- `yamllint apps/ platform/ data/ environments/ argocd/`: valida o estilo YAML dos manifestos e arquivos de valores.
- `for chart in apps/*/ platform/*/; do [ -f "$chart/Chart.yaml" ] && helm lint "$chart"; done`: executa o lint em todos os charts Helm que contêm `Chart.yaml`.
- `shellcheck scripts/*.sh`: verifica scripts shell quanto a portabilidade e bugs comuns.
- `markdownlint-cli2 '**/*.md'`: valida a documentação Markdown.
- `./scripts/bootstrap-lab.sh --role=sp1 --dry-run`: pré-visualiza o provisionamento do laboratório sem alterar o host.
- `./scripts/validate-cluster.sh`: verifica Docker, Helm, Kubernetes, Argo CD, serviços do host e conectividade após o bootstrap.

## Estilo de Codificação e Convenções de Nomenclatura

Use indentação de 2 espaços para YAML e valores Helm. Nomes de recursos, branches, labels e nomes de charts devem usar `kebab-case`, por exemplo, `uniplus-api-selecao`. Os recursos do Kubernetes devem incluir os labels padrão `app.kubernetes.io/*` e `app.kubernetes.io/part-of: uniplus`. Scripts shell devem usar Bash, manter o estilo de salvaguardas `set -u`/`pipefail` onde prático e evitar o vazamento de segredos nos logs.

## Diretrizes de Teste

Não há uma suíte de testes unitários de aplicação neste repositório. A validação é focada em configuração: execute YAML lint, Helm lint, ShellCheck, Markdown lint e verificações de laboratório antes de abrir um PR. Para alterações em `environments/prod-*`, documente o ambiente de laboratório utilizado e o caminho de rollback.

## Diretrizes de Commit e Pull Request

Use Conventional Commits, seguindo o histórico existente e o `CONTRIBUTING.md`: `feat(scope): ...`, `fix(scope): ...`, `docs(scope): ...` ou `chore(scope): ...`. Abra uma Issue antes de alterações não triviais. Os PRs devem descrever o que mudou, por que, como foi testado, ambientes afetados, riscos e atualizações de documentação. Mudanças em produção exigem atenção extra dos revisores (mínimo de 2 aprovações).

## Dicas de Segurança e Configuração

Nunca commite credenciais, kubeconfigs, chaves de unseal, tokens Cloudflare, certificados, dumps ou configurações locais geradas. Use placeholders na documentação e mantenha segredos reais no Vault ou em arquivos apenas locais ignorados pelo `.gitignore`. Relate vulnerabilidades de forma privada através do `SECURITY.md`, não em Issues públicas.
