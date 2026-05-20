# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Workflow Context:** This repository is part of the Uni+ ecosystem. Global workflow conventions (mandatory issues, branch naming, commits in pt-BR, GitHub organization, team) are defined in [CONTRIBUTING.md](./CONTRIBUTING.md). This file covers only what is specific to `uniplus-infra`.

@docs/visao-do-projeto.md

## O que este repositório é

IaC declarativa da plataforma Uni+. **Não contém código de aplicação** — apenas Helm charts, manifests Kubernetes, valores por ambiente, scripts de bootstrap e documentação operacional. As aplicações vivem em `uniplus-api` e `uniplus-web`; este repo descreve **como** elas são empacotadas, configuradas e implantadas.

GitOps é a fonte única de verdade: o ArgoCD reconcilia o estado do cluster com o conteúdo deste repositório. Mudanças manuais (`kubectl apply`, edição via UI) são reconciliadas/sobrescritas pelo ArgoCD.

## Topologia atual: standalone-compact

**A única infra operada hoje** (2026-05-19) é o ambiente `standalone-compact`:

- **Região:** OCI `sa-saopaulo-1` (home region; preserva Block Volume Always Free 200 GB cap)
- **k8s-host:** VM `VM.Standard.E4.Flex` 2 OCPU / 8 GB (escalável a 12 GB live-resize) · Reserved Public IP `137.131.131.6` · K3s + Helm + ArgoCD
- **data-host:** VM `VM.Standard.E4.Flex` 1 OCPU / 4 GB · private `10.2.2.11` · Postgres 18 + Kafka KRaft + MinIO + Vault + Redis em containers Docker gerenciados por systemd, com LVs em 1 disco de 100 GB
- **DNS:** `*.standalone.portaluni.com.br` (OCI DNS, zona `portaluni.com.br`) · TLS Let's Encrypt via cert-manager + Traefik IngressRoute
- **Custo mensal:** ~$9,60 PAYG (compute) + $0 storage (Always Free)

O modelo aspiracional dos **3 DCs lógicos (SP1+SP2+PA1)** está descrito em `docs/ARCHITECTURE.md §2.2 / §5.5` como referência futura para quando houver acordo formal com EVEO e DIRSI. Os ADRs do bloco 001/007 que decidiam o 3-DC puro estão marcados como **Superseded** por [ADR-008](docs/adrs/ADR-008-topologia-standalone.md).

## Comandos de validação

Não há test suite de aplicação — toda validação é de configuração.

```bash
# Tudo de uma vez (mesmo que o CI roda em .github/workflows/validate.yml)
make validate

# Ou alvos individuais
make yaml-lint        # yamllint (config: .yamllint.yaml)
make helm-lint        # helm lint em apps/ + platform/
make markdown-lint    # markdownlint-cli2
make shellcheck       # shellcheck nos scripts
make schema-validate  # values.yaml vs schemas dos charts (kubeconform render)
make helm-template    # render local de todos os charts × environments
```

Use `make help` para a lista atualizada.

## Operações no standalone-compact

```bash
# SSH ao cluster
ssh ubuntu@137.131.131.6                          # k8s-host (Reserved IP)
ssh -J ubuntu@137.131.131.6 ubuntu@10.2.2.11      # data-host via jump

# Bootstrap — manual via SSH após o tofu apply (sem cloud-init ainda, issue #387)
./scripts/bootstrap-standalone.sh --role=standalone-k8s [--dry-run]
./scripts/bootstrap-standalone.sh --role=standalone-data [--dry-run]

# Validação pós-bootstrap
./scripts/validate-standalone.sh                  # smoke completo dos 2 hosts
./scripts/validate-cluster.sh                     # smoke focado no K3s
./scripts/smoke-{dashboards,encryption-e2e,metrics-pipeline}.sh

# Resize OCPU/RAM (hot-resize via OCI CLI)
./scripts/resize-standalone-oci.sh poc            # default ~$9,60/mês
./scripts/resize-standalone-oci.sh hml            # ~$157/mês para HML
```

Sempre rodar `--dry-run` antes em mudanças no `bootstrap-standalone.sh`.

## Layout: por que está dividido assim

| Diretório | Conteúdo | Característica determinante |
|---|---|---|
| `apps/` | Helm charts das aplicações Uni+ (`uniplus-web`, `uniplus-api-{portal,selecao,ingresso}`, `clamav-scanner`, `keycloak-replica`, `apicurio-registry`, `kafka-ui`, `redis-ui`) | Workloads K8s puros, namespace `uniplus` |
| `platform/` | Componentes de plataforma K8s (Traefik, ArgoCD, Vault, External Secrets, cert-manager, observability/{prometheus,grafana,loki,tempo,otelcol}, storage, minio-console-proxy) | Rodam **dentro** do K8s, suportam `apps/` |
| `data/` | PostgreSQL, Kafka KRaft, MinIO, Redis | **Rodam fora do K8s** — containers gerenciados por systemd no data-host, em LVs dedicadas. Decisão deliberada: backup/restore/troubleshooting independem da saúde do K8s |
| `environments/standalone-compact/` | `values.yaml` com overrides de Helm | Defaults ficam em `apps/*/values.yaml` e `platform/*/values.yaml`; environment só sobrescreve o necessário |
| `argocd/` | `applicationset.yaml` + `project.yaml` | ApplicationSet matcha clusters com label `uniplus.io/managed=true` |
| `provisioning/oci/standalone-compact/` | OpenTofu — provisiona as 2 VMs OCI | Edits aqui geram custo real; planejar com `tofu plan` antes |

## Convenções específicas de manifests

- Indentação YAML: **2 espaços, sem tabs**.
- Nomes (charts, recursos, branches, labels): **kebab-case** — `uniplus-api-selecao`, nunca `uniplus_api_selecao`.
- Todos os recursos K8s carregam os labels padrão `app.kubernetes.io/{name,instance,version,managed-by}` **mais** `app.kubernetes.io/part-of: uniplus`.
- **Nunca** commitar credenciais, kubeconfigs, unseal keys do Vault, certificados, IPs internos UNIFESSPA. Secrets vivem no Vault e são injetadas via `ExternalSecret` — manifests no Git contêm apenas referências.
- `helm-docs` gera `README.md` dos charts a partir dos `values.yaml`; `values.schema.json` recomendado quando aplicável.

## Documentos a consultar antes de mudar algo não-trivial

- `docs/ARCHITECTURE.md` — visão arquitetural, diagramas C4, decisões e estratégia por componente. Inclui o §5.5 com as duas topologias (3-DC futuro / standalone-compact atual).
- `docs/RUNBOOKS.md` — bootstrap, failover (modelo 3-DC = referência histórica), backup, restore, troubleshooting do data-host.
- `docs/adrs/` — Architecture Decision Records. ADRs 001/007 estão Superseded; 002, 003, 004, 005, 006, 008+ são canônicos.
- `docs/validacao/` — relatórios de validação executadas (smoke standalone, dashboards, etc.).
