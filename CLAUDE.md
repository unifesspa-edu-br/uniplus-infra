# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Workflow Context:** This repository is part of the Uni+ ecosystem. Global workflow conventions (mandatory issues, branch naming, commits in pt-BR, GitHub organization, team) are defined in [CONTRIBUTING.md](./CONTRIBUTING.md). This file covers only what is specific to `uniplus-infra`.

## O que este repositório é

IaC declarativa da plataforma Uni+. **Não contém código de aplicação** — apenas Helm charts, manifests Kubernetes, valores por ambiente, scripts de bootstrap e documentação operacional. As aplicações vivem em `uniplus-api` e `uniplus-web`; este repo descreve **como** elas são empacotadas, configuradas e implantadas.

GitOps é a fonte única de verdade: o ArgoCD reconcilia o estado do cluster com o conteúdo deste repositório. Mudanças manuais (`kubectl apply`, edição via UI) são reconciliadas/sobrescritas pelo ArgoCD.

## Topologia: uniplus-prd

O ambiente operado é o `uniplus-prd`, em duas VMs Ubuntu:

- **uniplus-prod-app** (`200.139.48.121`): K3s, Helm e ArgoCD. Traefik, Vault, External Secrets, KES, APIs, web e observabilidade.
- **uniplus-prod-infra** (`200.139.48.122`): PostgreSQL com PostGIS, Redis, MinIO, Kafka e RabbitMQ em containers Docker sob systemd, só com TLS.
- **DNS e TLS:** `*.uniplus.unifesspa.edu.br` e certificado curinga `*.unifesspa.edu.br` instalado nas VMs.
- **Atualização:** manual por tag, sem sync automático (ADR-015). Os scripts vivos ficam em `scripts/servicos-no-host/`.

## Comandos de validação

Não há test suite de aplicação — toda validação é de configuração.

```bash
make validate         # o mesmo que o CI roda em .github/workflows/validate.yml
make yaml-lint        # yamllint (config: .yamllint.yaml)
make helm-lint        # helm lint em apps/ + platform/
make markdown-lint    # markdownlint-cli2
make shellcheck       # shellcheck nos scripts
make schema-validate  # values.yaml vs schemas dos charts (kubeconform render)
make helm-template    # render local de todos os charts
```

Use `make help` para a lista atualizada.

## Operações

Os scripts rodam nas VMs, aceitam `--dry-run` e leem `AMBIENTE` (`prd` por padrão):

```bash
./scripts/servicos-no-host/bootstrap-infra.sh [--dry-run]
./scripts/servicos-no-host/bootstrap-app.sh --revisao=vX.Y.Z [--dry-run]
./scripts/servicos-no-host/atualizar-producao.sh --revisao=vX.Y.Z [--dry-run]
```

Sempre rodar `--dry-run` antes em mudanças nos scripts. A ordem completa está em `docs/RUNBOOKS.md`.

## Layout: por que está dividido assim

| Diretório | Conteúdo | Característica determinante |
|---|---|---|
| `apps/` | Helm charts das aplicações (`uniplus-web`, `uniplus-api-host`, `uniplus-api-portal`, `unifesspa-geo-api`, `verificador-rede`, `clamav-espelho`, `keycloak-replica`, `apicurio-registry`, `kafka-ui`, `redis-ui`) | Workloads K8s; namespace por sistema (`uniplus`, `geo`) ou próprio da ferramenta |
| `platform/` | Componentes de plataforma (Traefik, ArgoCD, Vault, External Secrets, KES, observability, storage, minio-console-proxy) | Rodam no K8s e suportam `apps/` |
| `environments/uniplus-prd/` | `values.yaml` com overrides de Helm | Defaults ficam nos charts; o ambiente só sobrescreve o necessário |
| `argocd/` | `applicationset.yaml` + `project.yaml` + `applications/` | ApplicationSet seleciona clusters com `uniplus.io/managed=true` e o label `environment: uniplus-prd` |
| `scripts/servicos-no-host/` | Scripts das duas VMs | Serviços de dados rodam fora do K8s, em containers sob systemd |

## Convenções específicas de manifests

- Indentação YAML: **2 espaços, sem tabs**.
- Nomes (charts, recursos, branches, labels): **kebab-case** — `uniplus-api-selecao`, nunca `uniplus_api_selecao`.
- Todos os recursos K8s carregam os labels padrão `app.kubernetes.io/{name,instance,version,managed-by}` **mais** `app.kubernetes.io/part-of: uniplus`.
- **Nunca** commitar credenciais, kubeconfigs, unseal keys do Vault, certificados, IPs internos UNIFESSPA. Secrets vivem no Vault e são injetadas via `ExternalSecret` — manifests no Git contêm apenas referências.
- `helm-docs` gera `README.md` dos charts a partir dos `values.yaml`; `values.schema.json` recomendado quando aplicável.

## Documentos a consultar antes de mudar algo não-trivial

- `docs/RUNBOOKS.md` — bootstrap, atualização por tag, renovação de certificado, diagnóstico.
- `docs/vault-caminhos.md` — KV por sistema e ambiente, stores e mapa de caminhos.
- `docs/REPRODUCIBILITY.md` — o que é codificado e o que é manual.
- `docs/adrs/` — Architecture Decision Records.
