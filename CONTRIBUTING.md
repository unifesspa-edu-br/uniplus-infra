# Guia de Contribuição

Obrigado pelo interesse em contribuir com o `uniplus-infra`. Este documento descreve o processo recomendado para propor mudanças e o padrão esperado nas contribuições.

## Antes de começar

Por se tratar de infraestrutura crítica de uma instituição federal, **todas as mudanças passam por revisão técnica** do time CTIC/UNIFESSPA. Contribuições diretas em main não são permitidas — toda alteração entra via Pull Request com aprovação obrigatória.

## Fluxo de contribuição

### 1. Abra uma Issue antes do PR

Para qualquer mudança não trivial, abra primeiro uma Issue descrevendo:

- O problema que está resolvendo (ou a melhoria proposta)
- Justificativa técnica
- Impacto em ambientes existentes (lab e/ou produção)
- Dependências ou pré-requisitos

Issues triviais (correção de typo, ajuste de README) podem ir direto para PR.

### 2. Crie um branch a partir de `main`

```bash
git checkout -b feat/nome-da-feature
# ou
git checkout -b fix/descricao-do-bug
# ou
git checkout -b docs/atualizacao-runbook
```

### 3. Faça commits seguindo Conventional Commits

Veja [conventionalcommits.org](https://www.conventionalcommits.org/pt-br/v1.0.0/).

Exemplos:

```
feat(traefik): adiciona middleware de rate limiting
fix(postgres): corrige permissão de pgBouncer no Patroni
docs(runbooks): atualiza procedimento de failover
chore(deps): atualiza ArgoCD para 2.13.x
```

### 4. Garanta que validações passam

Antes de abrir o PR, execute localmente:

```bash
# Roda todos os linters (yaml + helm + markdown + shell)
make lint

# Roda lint + helm dependency update + validação contra values.schema.json
make validate

# Lista todos os targets disponíveis
make help
```

Targets individuais úteis durante desenvolvimento:

| Target | Função |
|---|---|
| `make yaml-lint` | yamllint nos diretórios de manifests/values |
| `make helm-lint` | helm lint em todos os charts (apps/ + platform/) |
| `make helm-template` | renderiza todas as combinações chart × environment |
| `make schema-validate` | valida values dos environments contra `values.schema.json` |
| `make markdown-lint` | markdownlint-cli2 em todos os `.md` |
| `make shellcheck` | shellcheck em `scripts/*.sh` |
| `make helm-deps` | `helm dependency update` em charts com dependências |
| `make helm-docs` | gera/atualiza READMEs a partir de `values.yaml` (exige helm-docs CLI) |
| `make clean` | remove `charts/` baixados, `*.tgz`, `Chart.lock` |

Os mesmos checks rodam em CI (`.github/workflows/validate.yml`) e bloqueiam o merge se falharem.

### 5. Abra o Pull Request

Padrão do título: `<tipo>: <descrição curta>`

Exemplo: `feat: adiciona Vault HA com 3 réplicas`

Descrição do PR deve incluir:

- **O que mudou** — resumo objetivo
- **Por que mudou** — referência à Issue
- **Como testou** — descrição dos testes realizados
- **Riscos** — impactos potenciais ou rollback necessário
- **Documentação atualizada** — se aplicável

### 6. Aguarde revisão

Pelo menos 1 aprovação do time CTIC é obrigatória. Mudanças no ambiente operacional (`environments/standalone-compact/`, `provisioning/oci/standalone-compact/`) ou no bootstrap exigem atenção redobrada do revisor e plano de rollback no PR. Quando o modelo 3-DC for revivido, mudanças em produção voltam a requerer 2 aprovações.

## Padrões de código

### Helm Charts

- Cada chart deve ter `Chart.yaml`, `values.yaml` (defaults), `README.md`
- Templates em `templates/` seguem [boas práticas oficiais](https://helm.sh/docs/chart_best_practices/)
- Use `helm-docs` para gerar README a partir dos values (`make helm-docs`). Configuração em `.helm-docs.yaml`. Charts ainda não migrados mantêm README hand-written; migração é gradual.
- **`values.schema.json` obrigatório** para charts em `platform/` (validação automática pelo Helm em `helm template`/`install`/`upgrade`). Chart wrapper `platform/vault/` e `platform/vault-transit/` servem de referência. Use `additionalProperties: true` em blocos compartilhados entre múltiplos charts (`networkPolicy`, `serviceMonitor`, `ingress`).

### YAML

- Indentação: 2 espaços, sem tabs
- Nomes em `kebab-case` (ex: `uniplus-api-portal`, não `uniplus_api_portal`)
- Labels obrigatórios em todos os recursos K8s:
  - `app.kubernetes.io/name`
  - `app.kubernetes.io/instance`
  - `app.kubernetes.io/version`
  - `app.kubernetes.io/managed-by`
  - `app.kubernetes.io/part-of: uniplus`

### Documentação

- Markdown em todos os documentos
- Diagramas em PlantUML (fonte versionada) ou Mermaid inline
- Imagens em `docs/images/`
- Atualize o documento relevante junto com a mudança

## O que NÃO commitar

🚫 **Nunca commite:**

- Senhas, tokens, chaves privadas, certificados
- IPs internos da UNIFESSPA (use placeholders)
- Detalhes de regras do Palo Alto institucional
- Kubeconfig de produção
- Vault unseal keys ou tokens de provider

Em caso de commit acidental de informação sensível, **avise imediatamente** o coordenador técnico para rotação de credenciais.

## Reportando vulnerabilidades

Vulnerabilidades de segurança devem ser reportadas em privado conforme [SECURITY.md](SECURITY.md), **nunca via Issues públicas**.

## Comunicação

- Issues e PRs no GitHub para discussão técnica
- E-mail institucional para tópicos sensíveis ou estratégicos
- Reuniões periódicas do time CTIC para alinhamento de roadmap

---

Obrigado por contribuir com a melhoria da infraestrutura institucional da UNIFESSPA.
