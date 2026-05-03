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
CHARTS_APPS     := $(wildcard apps/*/Chart.yaml)
CHARTS_PLATFORM := $(wildcard platform/*/Chart.yaml)
CHARTS_ALL      := $(CHARTS_APPS) $(CHARTS_PLATFORM)
CHART_DIRS      := $(dir $(CHARTS_ALL))

# Diretórios validados pelo yamllint (mesma lista do CI).
YAML_DIRS := apps/ platform/ data/ environments/ argocd/

# Environments existentes (atualizar quando san-* / hml-* forem criados).
ENVS := lab-sp1 lab-sp2 lab-pa1 prod-sp1 prod-sp2 prod-pa1

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
validate: helm-deps lint schema-validate  ## Lint + render de templates contra schemas
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
	@for chart_dir in $(CHART_DIRS); do \
	    chart_name=$$(basename "$$chart_dir"); \
	    for env in $(ENVS); do \
	        OUT=$$(helm template "$$chart_name" "$$chart_dir" \
	                -f "environments/$$env/values.yaml" 2>&1); \
	        if echo "$$OUT" | grep -q "Error"; then \
	            printf "  $(RED)✗$(RESET) $$chart_name × $$env\n"; \
	            echo "$$OUT" | grep -A2 Error | head -5; \
	        else \
	            KINDS=$$(echo "$$OUT" | grep -c "^kind:" || true); \
	            printf "  $(GREEN)✓$(RESET) $$chart_name × $$env  ($$KINDS recursos)\n"; \
	        fi; \
	    done; \
	done

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
