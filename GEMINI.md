# GEMINI.md

Este arquivo fornece contexto e instruções para interações do Gemini CLI neste repositório de infraestrutura da plataforma **Uni+**.

> **Nota de Contexto:** Este repositório faz parte do ecossistema Uni+. Convenções de workflow, commits em pt-BR e padrões de contribuição estão detalhados no arquivo [CONTRIBUTING.md](./CONTRIBUTING.md) deste repositório.

## 🚀 Visão Geral do Projeto

O **uniplus-infra** é o repositório de Infraestrutura como Código (IaC) e GitOps da plataforma Uni+ (UNIFESSPA). Ele gerencia o provisionamento e a operação de múltiplos ambientes (Lab e Produção) distribuídos em 3 Datacenters lógicos: **SP1**, **SP2** (ativos) e **PA1** (institucional/DR).

### 🛠️ Stack Tecnológica
- **Orquestração:** Kubernetes (K3s)
- **GitOps:** ArgoCD (ApplicationSet)
- **Service Layer:** Helm 3
- **Stateful (Host-based):** PostgreSQL (Patroni), Kafka (KRaft), MinIO (Distributed)
- **Borda/Ingress:** Traefik, Cloudflare Tunnel (Lab)
- **Segurança:** HashiCorp Vault + External Secrets Operator
- **Observabilidade:** Grafana, Prometheus, Loki, Tempo, OpenTelemetry

## 📂 Estrutura de Pastas

- `apps/`: Helm charts das aplicações Uni+ (.NET 10 / Angular).
- `platform/`: Componentes de infraestrutura do cluster (Traefik, Vault, etc).
- `data/`: Configurações de serviços stateful executados via Docker no host.
- `environments/`: Valores específicos por ambiente (`lab-sp1`, `prod-sp1`, etc).
- `argocd/`: Manifestos de bootstrap do ArgoCD (ApplicationSets).
- `scripts/`: Automação de setup, limpeza e validação.
- `docs/`: Documentação arquitetural e runbooks operacionais.

## ⚙️ Comandos Chave e Fluxos

### 🧪 Setup de Laboratório (Local)
Para provisionar uma máquina de laboratório do zero:
```bash
# Para a máquina principal (SP1 - Ryzen/Arch)
./scripts/bootstrap-lab.sh --role=sp1

# Para a máquina secundária (SP2 - i7/Ubuntu)
./scripts/bootstrap-lab.sh --role=sp2 --enable-cloudflared
```

### 📦 Gestão de Serviços Stateful (Host)
Os bancos de dados e mensageria rodam fora do K8s via Docker Compose:
```bash
cd data/postgres && docker compose up -d
cd data/kafka && docker compose up -d
cd data/minio && docker compose up -d
```

### ⚓ Operações Kubernetes (GitOps)
Embora o ArgoCD automatize o deploy, você pode interagir manualmente:
```bash
# Validar saúde do cluster
./scripts/validate-cluster.sh

# Verificar logs de uma aplicação
kubectl logs -f deployment/uniplus-api-selecao -n uniplus

# Acessar UI do ArgoCD localmente
kubectl port-forward -n argocd svc/argocd-server 8080:443
```

## 📝 Convenções de Desenvolvimento

1.  **GitOps First:** Evite `kubectl apply` manual para mudanças permanentes. Altere os Helm charts em `apps/` ou os valores em `environments/` e faça commit.
2.  **Conventional Commits:** Siga o padrão `feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `ci:`. Commits devem ser em **pt-BR**. Detalhes em [CONTRIBUTING.md](./CONTRIBUTING.md).
3.  **Secrets:** NUNCA suba segredos no Git. Use o Vault e referencie via `ExternalSecret`.
4.  **Charts Helm:** Mantenha os charts genéricos e use arquivos de valores em `environments/` para diferenciação.
5.  **Independência de DC:** Mudanças não devem criar dependências síncronas obrigatórias entre os clusters de cada DC.
6.  **Aprovações:** Alterações em `environments/prod-*` requerem **2 aprovações** e plano de rollback explícito no PR.

## 📖 Referências Úteis
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - Visão técnica completa.
- [docs/SETUP.md](docs/SETUP.md) - Passo a passo detalhado de provisionamento.
- [docs/RUNBOOKS.md](docs/RUNBOOKS.md) - Procedimentos de failover e recuperação.
