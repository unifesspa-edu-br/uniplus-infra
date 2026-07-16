# Makefile do uniplus-infra
#
# Targets agrupados por área. `make help` lista tudo.
# CI roda os mesmos checks via .github/workflows/validate.yml — manter alinhado.

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
MAKEFLAGS += --no-print-directory

# ============================================================================
# Configuração
# ============================================================================

# Charts a serem processados. Atualizar se nova área surgir.
#
# platform/*/Chart.yaml sozinho não pega platform/observability/<x>/Chart.yaml
# (1 nível a mais) — combinado explicitamente, senão helm-lint/schema-validate/
# helm-template pulam os 5 charts de observability silenciosamente (achado real
# em 2026-07-13: nenhum dos três cobria observability, embora o job "Manifest
# Validate" do CI, que não usa este Makefile, já cobrisse via glob próprio).
CHARTS_APPS     := $(wildcard apps/*/Chart.yaml)
CHARTS_PLATFORM := $(wildcard platform/*/Chart.yaml) $(wildcard platform/observability/*/Chart.yaml)
CHARTS_ALL      := $(CHARTS_APPS) $(CHARTS_PLATFORM)
CHART_DIRS      := $(dir $(CHARTS_ALL))

# Diretórios validados pelo yamllint (mesma lista do CI).
YAML_DIRS := apps/ platform/ data/ environments/ argocd/

# Environments existentes (atualizar quando san-* / 3-DC forem criados).
ENVS := standalone-compact hml-standalone-single

# Regressão de roteamento path-based: os três charts que compartilham a
# convenção Host() + PathPrefix() precisam continuar renderizando nos
# ambientes existentes antes do rollout. O lab não integra ENVS porque nem
# todos os charts de plataforma são aplicáveis nele.
ROUTING_CHART_DIRS := apps/uniplus-api-host/ apps/uniplus-api-portal/ apps/uniplus-web/
ROUTING_ENVS       := standalone-compact lab-standalone-single hml-standalone-single

# Comando markdownlint via npx (não exige instalação global).
MARKDOWNLINT := npx --yes markdownlint-cli2

# helm-docs via go install ou docker — configurável.
HELM_DOCS ?= helm-docs

# ============================================================================
# Cores
# ============================================================================

GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
BLUE   := \033[0;34m
RESET  := \033[0m

# ============================================================================
# Help
# ============================================================================

.PHONY: help
help:  ## Lista os targets disponíveis com descrição
	@echo ""
	@printf "$(BLUE)Uni+ infra — Makefile$(RESET)\n"
	@echo ""
	@printf "$(GREEN)Validação (mesmo conjunto do CI):$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '^(yaml-lint|helm-lint|markdown-lint|shellcheck|schema-validate|lint|validate|all)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@printf "$(GREEN)Helm:$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -E '^helm-' | grep -vE '^(helm-lint)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""
	@printf "$(GREEN)Outros:$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | grep -vE '^(yaml-lint|helm-lint|markdown-lint|shellcheck|schema-validate|lint|validate|all|help|helm-)' | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(YELLOW)%-20s$(RESET) %s\n", $$1, $$2}'
	@echo ""

# ============================================================================
# Validação — chamada por CI e desenvolvedores antes do PR
# ============================================================================

.PHONY: yaml-lint
yaml-lint:  ## Roda yamllint nos diretórios manifests/values
	@printf "$(BLUE)→ yamllint$(RESET)\n"
	yamllint -c .yamllint.yaml $(YAML_DIRS)

.PHONY: helm-lint
helm-lint:  ## Roda helm lint em todos os charts (apps/ e platform/)
	@printf "$(BLUE)→ helm lint$(RESET)\n"
	@FAILS=0; \
	for chart in $(CHART_DIRS); do \
	    echo "  Linting $$chart"; \
	    if ! helm lint "$$chart" >/tmp/helm-lint-$$$$.log 2>&1; then \
	        cat /tmp/helm-lint-$$$$.log; FAILS=$$((FAILS+1)); \
	    fi; \
	    rm -f /tmp/helm-lint-$$$$.log; \
	done; \
	if [ "$$FAILS" -gt 0 ]; then \
	    printf "$(RED)✗ $$FAILS chart(s) com falha em helm lint$(RESET)\n"; \
	    exit 1; \
	fi

.PHONY: markdown-lint
markdown-lint:  ## Roda markdownlint-cli2 em todos os .md
	@printf "$(BLUE)→ markdownlint$(RESET)\n"
	$(MARKDOWNLINT) '**/*.md' '!**/charts/**' '!**/node_modules/**'

.PHONY: shellcheck
shellcheck:  ## Roda shellcheck em scripts/*.sh (skip gracefully se não instalado)
	@printf "$(BLUE)→ shellcheck$(RESET)\n"
	@if command -v shellcheck >/dev/null 2>&1; then \
	    shellcheck scripts/*.sh; \
	else \
	    printf "$(YELLOW)⚠ shellcheck não instalado localmente — pulando (CI cobre via ludeeus/action-shellcheck)$(RESET)\n"; \
	    printf "  Instalar: pacman -S shellcheck (Arch) | apt install shellcheck (Ubuntu)\n"; \
	fi

.PHONY: schema-validate
schema-validate:  ## Valida values.yaml dos environments contra os schemas dos charts
	@printf "$(BLUE)→ schema-validate$(RESET)\n"
	@FAILS=0; \
	for chart_dir in $(CHART_DIRS); do \
	    chart_name=$$(basename "$$chart_dir"); \
	    if [ ! -f "$$chart_dir/values.schema.json" ]; then \
	        continue; \
	    fi; \
	    for env in $(ENVS); do \
	        echo "  $$chart_name × $$env"; \
	        if ! helm template "$$chart_name" "$$chart_dir" \
	                -f "environments/$$env/values.yaml" \
	                >/dev/null 2>/tmp/schema-$$$$.log; then \
	            cat /tmp/schema-$$$$.log; FAILS=$$((FAILS+1)); \
	        fi; \
	        rm -f /tmp/schema-$$$$.log; \
	    done; \
	done; \
	if [ "$$FAILS" -gt 0 ]; then \
	    printf "$(RED)✗ $$FAILS combinação(ões) chart×env falharam na validação de schema$(RESET)\n"; \
	    exit 1; \
	fi

.PHONY: lint
lint: yaml-lint helm-lint markdown-lint shellcheck  ## Roda todos os linters

.PHONY: validate
validate: helm-deps lint schema-validate routing-validate  ## Lint + render de templates contra schemas
# Ordem importa: helm-deps PRIMEIRO popula charts/ — sem isso, helm-lint e
# schema-validate podem falhar em fresh checkout com "missing in charts/ directory".

.PHONY: all
all: validate  ## Alias de validate (default do CI)

# ============================================================================
# Helm — operações específicas
# ============================================================================

.PHONY: helm-deps
helm-deps:  ## Roda helm dependency update em todos os charts com dependências
	@printf "$(BLUE)→ helm dependency update$(RESET)\n"
	@for chart in $(CHART_DIRS); do \
	    if [ -f "$$chart/Chart.yaml" ] && grep -q '^dependencies:' "$$chart/Chart.yaml"; then \
	        echo "  $$chart"; \
	        helm dependency update "$$chart" >/dev/null 2>&1 || \
	            { echo "  ✗ falha em $$chart"; exit 1; }; \
	    fi; \
	done

.PHONY: helm-template
helm-template:  ## Renderiza todos os charts × environments (smoke local)
	@printf "$(BLUE)→ helm template (todos chart × env)$(RESET)\n"
	@# Capturar exit code via `if helm template`, não `OUT=$(helm template ...)`.
	@# Com .SHELLFLAGS=-euo pipefail -c, atribuição com falha aborta o loop
	@# imediatamente — usuário nunca vê quais outras combinações falharam.
	@# No ramo de falha, o `grep | head` pode não encontrar 'Error/error'
	@# (ex.: 'helm: command not found') e, sob pipefail, exit 1 do grep
	@# abortaria o loop — fallback para `tail` garante que algo seja exibido.
	@for chart_dir in $(CHART_DIRS); do \
	    chart_name=$$(basename "$$chart_dir"); \
	    for env in $(ENVS); do \
	        if OUT=$$(helm template "$$chart_name" "$$chart_dir" \
	                -f "environments/$$env/values.yaml" 2>&1); then \
	            KINDS=$$(echo "$$OUT" | grep -c "^kind:" || true); \
	            printf "  $(GREEN)✓$(RESET) $$chart_name × $$env  ($$KINDS recursos)\n"; \
	        else \
	            printf "  $(RED)✗$(RESET) $$chart_name × $$env\n"; \
	            { echo "$$OUT" | grep -A2 -E "Error|error" | head -5 \
	                || echo "$$OUT" | tail -10; } || true; \
	        fi; \
	    done; \
	done

.PHONY: routing-validate
routing-validate:  ## Valida os charts path-based em standalone-compact, lab e HML
	@printf "$(BLUE)→ validação de roteamento path-based$(RESET)\n"
	@FAILS=0; \
	for chart_dir in $(ROUTING_CHART_DIRS); do \
	    chart_name=$$(basename "$$chart_dir"); \
	    printf "  $$chart_name: helm lint\n"; \
	    if ! helm lint "$$chart_dir" >/tmp/routing-lint-$$$$.log 2>&1; then \
	        cat /tmp/routing-lint-$$$$.log; FAILS=$$((FAILS+1)); \
	    fi; \
	    rm -f /tmp/routing-lint-$$$$.log; \
	    for env in $(ROUTING_ENVS); do \
	        printf "  $$chart_name × $$env: helm template\n"; \
	        if ! helm template "$$chart_name" "$$chart_dir" \
	                -f "environments/$$env/values.yaml" \
	                >/tmp/routing-template-$$$$.yaml 2>/tmp/routing-template-$$$$.log; then \
	            cat /tmp/routing-template-$$$$.log; FAILS=$$((FAILS+1)); \
	        fi; \
	        rm -f /tmp/routing-template-$$$$.yaml /tmp/routing-template-$$$$.log; \
	    done; \
	    if [ -f "$$chart_dir/values.schema.json" ]; then \
	        printf "  $$chart_name: values.schema.json validado por helm template\n"; \
	    else \
	        printf "  $$chart_name: sem values.schema.json (não aplicável)\n"; \
	    fi; \
	done; \
	if [ "$$FAILS" -gt 0 ]; then \
	    printf "$(RED)✗ $$FAILS validação(ões) de roteamento falharam$(RESET)\n"; \
	    exit 1; \
	fi

.PHONY: helm-docs
helm-docs:  ## Gera README.md dos charts a partir de values.yaml e README.md.gotmpl
	@printf "$(BLUE)→ helm-docs$(RESET)\n"
	@# Tenta invocar HELM_DOCS --version diretamente. Funciona com binário simples
	@# (`helm-docs`) e com wrapper docker (`docker run ... jnorwood/helm-docs ...`).
	@# `command -v` não funcionaria com strings que contêm argumentos.
	@if ! $(HELM_DOCS) --version >/dev/null 2>&1; then \
	    printf "$(RED)✗ helm-docs não disponível (HELM_DOCS=$(HELM_DOCS))$(RESET)\n"; \
	    echo "  Instalar: go install github.com/norwoodj/helm-docs/cmd/helm-docs@latest"; \
	    echo "  Ou via docker: HELM_DOCS='docker run --rm -v \"\$$(pwd):/work\" -w /work jnorwood/helm-docs:latest helm-docs' make helm-docs"; \
	    exit 1; \
	fi
	$(HELM_DOCS) --chart-search-root=. --chart-to-generate=apps,platform

# ============================================================================
# Outros
# ============================================================================

.PHONY: clean
clean:  ## Remove charts/ baixados, .tgz e arquivos temporários
	@printf "$(BLUE)→ clean$(RESET)\n"
	@find . -type d -name 'charts' -not -path './node_modules/*' -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name '*.tgz' -not -path './node_modules/*' -delete 2>/dev/null || true
	@find . -type f -name 'Chart.lock' -not -path './node_modules/*' -delete 2>/dev/null || true
	@printf "$(GREEN)✓ limpo$(RESET)\n"

.PHONY: list-charts
list-charts:  ## Lista todos os charts existentes (apps/ e platform/)
	@for chart in $(CHART_DIRS); do echo "  $$chart"; done

.PHONY: list-envs
list-envs:  ## Lista todos os environments existentes
	@for env in $(ENVS); do echo "  $$env"; done

# Default target
.DEFAULT_GOAL := help
