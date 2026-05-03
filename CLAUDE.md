# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> **Workflow Context:** This repository is part of the Uni+ ecosystem. Global workflow conventions (mandatory issues, branch naming, commits in pt-BR, GitHub organization, team) are defined in [CONTRIBUTING.md](./CONTRIBUTING.md). This file covers only what is specific to `uniplus-infra`.

## O que este repositório é

IaC declarativa da plataforma Uni+. **Não contém código de aplicação** — apenas Helm charts, manifests Kubernetes, valores por ambiente, scripts de bootstrap de laboratório e documentação operacional. As aplicações vivem em `uniplus-api` e `uniplus-web`; este repo descreve **como** elas são empacotadas, configuradas e implantadas.

GitOps é a fonte única de verdade: o ArgoCD em cada cluster reconcilia o estado do cluster com o conteúdo do repositório. Mudanças manuais (`kubectl apply`, edição via UI) são reconciliadas/sobrescritas pelo ArgoCD.

## Comandos de validação

Não há test suite de aplicação — toda validação é de configuração. Antes de PR, rodar (mesmos checks do CI em `.github/workflows/validate.yml`):

```bash
# YAML lint (config em .yamllint.yaml)
yamllint -c .yamllint.yaml apps/ platform/ data/ environments/ argocd/

# Helm lint em todos os charts (apps/ e platform/)
for chart in apps/*/ platform/*/; do
  [ -f "$chart/Chart.yaml" ] && helm lint "$chart"
done

# ShellCheck nos scripts
shellcheck scripts/*.sh

# Markdown lint
markdownlint-cli2 '**/*.md'
```

CI atual roda esses checks em modo *warning-only* (`|| true`, `continue-on-error`) — falhas não bloqueiam merge automaticamente, mas devem ser tratadas. O `CONTRIBUTING.md` referencia alvos `make helm-lint / yaml-lint / kube-validate`, mas **não há Makefile ainda** — usar os comandos acima diretamente.

## Operações de laboratório

Scripts em `scripts/` gerenciam o ambiente de validação local:

```bash
./scripts/bootstrap-lab.sh --role={sp1|sp2|pa1} [--dry-run]   # provisiona K3s + Docker + cloudflared
./scripts/validate-cluster.sh                                       # checa Docker/Helm/K8s/ArgoCD/serviços
./scripts/teardown-lab.sh                                           # limpa
```

Sempre rodar `--dry-run` antes em mudanças no bootstrap. O script detecta Arch vs Ubuntu automaticamente e tem flags `--skip-k3s`, `--skip-docker`, `--enable-cloudflared`.

## Arquitetura — modelo dos 3 DCs lógicos

A plataforma é modelada como **`SP1` + `SP2` + `PA1`**, e essa nomenclatura permeia diretórios, charts e valores. Entender a divisão de papéis é pré-requisito para tocar qualquer coisa:

- **`SP1` e `SP2`** (datacenters EVEO Cotia/Osasco): atendem tráfego de usuário em **ativo-ativo**. Cada um é um cluster K3s independente — **não há cluster K8s estendido entre DCs**.
- **`PA1`** (datacenter institucional UNIFESSPA, Marabá): **não é witness simples**. Hospeda LDAP institucional, fonte OIDC institucional (`pa1-oidc-source`), destino de backup e retenção de observabilidade. Pode ficar fora algumas horas sem derrubar o atendimento — `SP1`/`SP2` continuam servindo e sincronizam o backlog quando `PA1` retorna.

**Princípio "ativo-ativo no nível da plataforma":** cada componente usa o mecanismo nativo de HA (Patroni para Postgres, KRaft para Kafka, modo distribuído do MinIO, etc.). Onde multi-writer limpo não existe, distribui-se responsabilidade com failover controlado — **nunca simular multi-master artificial**.

`environments/lab-pa1/` é o cluster K3s no host i7 simulando o DC institucional PA1 (renomeado de `lab-witness` em 2026-05-03 conforme issue #13 e ADR-007). Hospeda o Vault Transit + componentes legados em containers Docker (etcd, keycloak-master, minio-master, backup-target).

## Layout: por que está dividido assim

| Diretório | Conteúdo | Característica determinante |
|---|---|---|
| `apps/` | Helm charts das aplicações Uni+ (`uniplus-web`, `uniplus-api-{portal,selecao,ingresso}`, `clamav-scanner`, `keycloak-replica`) | Workloads K8s puros, namespace `uniplus` |
| `platform/` | Componentes de plataforma K8s (Traefik, ArgoCD, Vault, External Secrets, cert-manager, cloudflared, observability) | Rodam **dentro** do K8s, suportam `apps/` |
| `data/` | PostgreSQL (+ Patroni + PgBouncer), Kafka KRaft, MinIO, Redis | **Rodam fora do K8s** — containers gerenciados por systemd no host, em LVM dedicada no NVMe. Decisão deliberada: backup/restore/troubleshooting independem da saúde do K8s |
| `environments/{lab,prod}-{sp1,sp2,pa1}/` | `values.yaml` com overrides de Helm por ambiente | Defaults ficam em `apps/*/values.yaml` e `platform/*/values.yaml`; ambiente só sobrescreve o necessário |
| `argocd/` | `applicationset.yaml` + `project.yaml` (bootstrap GitOps) | Aplica os charts conforme o ambiente do cluster |

Mudanças em `environments/prod-*` requerem **2 aprovações** (vs. 1 padrão), descrição do lab onde foi testado e plano de rollback explícito no PR.

## Convenções específicas de manifests

- Indentação YAML: **2 espaços, sem tabs**.
- Nomes (charts, recursos, branches, labels): **kebab-case** — `uniplus-api-selecao`, nunca `uniplus_api_selecao`.
- Todos os recursos K8s carregam os labels padrão `app.kubernetes.io/{name,instance,version,managed-by}` **mais** `app.kubernetes.io/part-of: uniplus`.
- **Nunca** commitar credenciais, kubeconfigs, unseal keys do Vault, tokens Cloudflare, certificados, IPs internos UNIFESSPA ou regras do Palo Alto. Secrets vivem no Vault e são injetadas via `ExternalSecret` — manifests no Git contêm apenas referências.
- `helm-docs` para gerar `README.md` dos charts a partir dos `values.yaml`; `values.schema.json` recomendado quando aplicável.

## Documentos a consultar antes de mudar algo não-trivial

- `docs/ARCHITECTURE.md` — visão arquitetural completa, diagramas C4, decisões e estratégia por componente. **É a fonte sobre o "porquê" das escolhas** (3 DCs, stateful fora do K8s, ativo-ativo, soberania institucional).
- `docs/SETUP.md` — passo-a-passo das máquinas de laboratório (Ryzen 9950X / Arch = sp1, Core i7 / Ubuntu = sp2).
- `docs/VALIDATION-PLAN.md` — plano de validação em laboratório (a ser executado antes de promover algo a produção).
- `docs/RUNBOOKS.md` — failover, backup, restore.
