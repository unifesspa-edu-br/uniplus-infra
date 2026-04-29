# ArgoCD Bootstrap

Configurações do ArgoCD para o Uni+: AppProject e ApplicationSets.

## Visão geral

O ArgoCD é instalado em **cada cluster** (lab-sp1, lab-sp2, prod-sp1, prod-sp2) e gerencia o ciclo de vida das aplicações Uni+ neste cluster.

A instalação inicial do ArgoCD é feita pelo script `scripts/bootstrap-lab.sh`. Após instalado, os manifests neste diretório são aplicados via `kubectl apply -f` (uma vez), e a partir daí o ArgoCD se autogerencia (incluindo seus próprios upgrades).

## Estrutura

```
argocd/
├── README.md              # este arquivo
├── project.yaml           # AppProject 'uniplus'
└── applicationset.yaml    # ApplicationSets para apps + platform
```

## Como funciona

### AppProject

`project.yaml` define um AppProject chamado `uniplus` que:

- Permite repos da org `unifesspa-edu-br`
- Restringe destinos a este cluster
- Define roles RBAC (ctic-admin, developer)
- Bloqueia ResourceQuota/NetworkPolicy de virem do Git (gerenciados localmente)

### ApplicationSets

`applicationset.yaml` contém **2 ApplicationSets**:

1. **uniplus-apps** — gera Applications para cada chart em `apps/`:
   - uniplus-web
   - uniplus-api-portal
   - uniplus-api-selecao
   - uniplus-api-ingresso
   - clamav-scanner
   - keycloak-replica

2. **uniplus-platform** — gera Applications para componentes de plataforma:
   - traefik, cert-manager, external-secrets, vault, cloudflared
   - observability (prometheus, grafana, loki, tempo, otel-collector)

Cada ApplicationSet usa **matrix generator** combinando:
- Cada cluster registrado com label `uniplus.io/managed=true`
- Cada componente (app ou platform)

E injeta **2 valueFiles**:
- `values.yaml` (defaults do chart)
- `environments/<environment>/values.yaml` (overrides do cluster)

## Aplicação

Após o ArgoCD estar instalado:

```bash
# Registrar este cluster
argocd cluster add <context> --label uniplus.io/managed=true \
                              --label environment=lab-sp1

# Aplicar AppProject
kubectl apply -f argocd/project.yaml

# Aplicar ApplicationSets
kubectl apply -f argocd/applicationset.yaml

# Verificar
argocd app list
```

## Sincronização

Por padrão, todos os ApplicationSets têm:

- `automated.prune: true` — remove recursos deletados do Git
- `automated.selfHeal: true` — corrige drift automaticamente
- `syncOptions: CreateNamespace=true` — cria namespaces se não existirem
- `retry.limit: 5` com backoff exponencial

## Relacionamento com a documentação

- Setup inicial do ArgoCD: [docs/SETUP.md](../docs/SETUP.md#6-instalação-do-kubernetes-k3s)
- Operação: [docs/RUNBOOKS.md](../docs/RUNBOOKS.md#12-deploy-de-mudança-via-gitops)
