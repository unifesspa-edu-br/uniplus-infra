# GEMINI.md

Contexto e instruções para interações do Gemini CLI no repositório de infra da plataforma **Uni+**.

> **Nota de Contexto:** Faz parte do ecossistema Uni+. Convenções de workflow, commits em pt-BR e padrões de contribuição estão em [CONTRIBUTING.md](./CONTRIBUTING.md). A visão de produto vem do monorepo:

@docs/visao-do-projeto.md

## 🚀 Visão Geral do Projeto

**uniplus-infra** é o repositório de IaC e GitOps da plataforma Uni+ (UNIFESSPA). Em 2026-05-19 a única infra operada é o ambiente `standalone-compact` (1 cluster K3s + 1 data-host externo em OCI GRU, shape E4.Flex AMD, ~$9,60/mês PAYG). O modelo aspiracional dos 3 DCs lógicos (**SP1+SP2+PA1**) está descrito em `docs/ARCHITECTURE.md §5.5` como referência futura — adoção depende de acordo formal com EVEO e DIRSI. Os ADRs 001/007 que decidiam o 3-DC puro estão Superseded.

### 🛠️ Stack Tecnológica

- **Orquestração:** Kubernetes (K3s)
- **GitOps:** ArgoCD (ApplicationSet)
- **Service Layer:** Helm 3
- **Stateful (host via systemd + Docker):** PostgreSQL 18, Kafka 4.2 KRaft, MinIO single-node, Redis 8, Vault Shamir 5/3
- **Borda/Ingress:** Traefik IngressRoute + cert-manager Let's Encrypt
- **Segurança:** HashiCorp Vault + External Secrets Operator
- **Observabilidade:** Grafana, Prometheus, Loki, Tempo, OpenTelemetry Collector

## 📂 Estrutura de Pastas

- `apps/` — Helm charts das aplicações Uni+ (.NET 10 / Angular)
- `platform/` — Componentes de infraestrutura do cluster (Traefik, Vault, etc.)
- `data/` — Configurações dos services stateful no data-host (referência)
- `environments/standalone-compact/` — Valores do único ambiente operacional
- `argocd/` — Bootstrap GitOps (ApplicationSet + AppProject)
- `provisioning/oci/standalone-compact/` — OpenTofu das 2 VMs OCI
- `scripts/` — Automação de bootstrap, validação, smokes
- `docs/` — Arquitetura, ADRs, runbooks, validação executada

## ⚙️ Comandos Chave e Fluxos

### Validação local (mesmo que o CI roda)

```bash
make validate          # tudo (yaml-lint + helm-lint + markdown + shellcheck + schema-validate)
make help              # lista atualizada de alvos
```

### Bootstrap do standalone-compact

Após o `tofu apply` em `provisioning/oci/standalone-compact/`, rode o `bootstrap-standalone.sh` **manualmente via SSH** em cada VM (sem cloud-init ainda — issue #387):

```bash
./scripts/bootstrap-standalone.sh --role=standalone-k8s [--dry-run]
./scripts/bootstrap-standalone.sh --role=standalone-data [--dry-run]
```

### Operações de cluster

```bash
# Smoke completo
./scripts/validate-standalone.sh

# Smoke por área
./scripts/smoke-dashboards.sh
./scripts/smoke-encryption-e2e.sh
./scripts/smoke-metrics-pipeline.sh

# SSH
ssh ubuntu@137.131.131.6                          # k8s-host
ssh -J ubuntu@137.131.131.6 ubuntu@10.2.2.11      # data-host via jump

# Acessar ArgoCD
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

## 📝 Convenções de Desenvolvimento

1. **GitOps First:** Evite `kubectl apply` manual para mudanças permanentes. Altere `apps/`, `platform/` ou `environments/standalone-compact/values.yaml` e faça commit — ArgoCD reconcilia.
2. **Conventional Commits em pt-BR:** `feat(scope): ...`, `fix(scope): ...`, `chore(scope): ...`, `docs(scope): ...`. Subject em indicativo presente 3ª pessoa (`adiciona`, `corrige`, `remove`). Detalhes em [CONTRIBUTING.md](./CONTRIBUTING.md).
3. **Secrets:** NUNCA suba segredos no Git. Use o Vault e referencie via `ExternalSecret`.
4. **Charts Helm:** Mantenha os charts genéricos; diferenciação fica em `environments/standalone-compact/values.yaml`.
5. **Provisionamento OCI:** mudanças em `provisioning/oci/standalone-compact/` geram custo real — rodar `tofu plan` e revisar antes de aplicar.

## 📖 Referências Úteis

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — visão técnica, diagramas C4, §5.5 com as topologias
- [docs/RUNBOOKS.md](docs/RUNBOOKS.md) — bootstrap, failover, backup, troubleshooting
- [docs/adrs/](docs/adrs/) — ADRs 008+ são canônicos; 001/007 estão Superseded
- [docs/validacao/](docs/validacao/) — relatórios de validação executadas
