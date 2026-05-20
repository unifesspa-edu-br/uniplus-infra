# ArgoCD Bootstrap

Configurações do ArgoCD para o Uni+: AppProject e ApplicationSets.

## Visão geral

O ArgoCD é instalado no cluster do ambiente operacional (`standalone-compact`) e gerencia o ciclo de vida das aplicações Uni+. O design é multi-cluster (o ApplicationSet matcha qualquer cluster com o label `uniplus.io/managed=true`), pronto para o dia em que o modelo 3-DC for revivido.

A instalação inicial do ArgoCD é feita pelo `scripts/bootstrap-standalone.sh` (role `standalone-k8s`). Após instalado, os manifests neste diretório são aplicados via `kubectl apply -f` (uma vez), e a partir daí o ArgoCD se autogerencia (incluindo seus próprios upgrades).

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
   - storage, minio-console-proxy, traefik, cert-manager, external-secrets, vault, vault-transit, vault-transit-bootstrap
   - observability (prometheus, grafana, loki, tempo, otel-collector)

Cada ApplicationSet usa **matrix generator** combinando:
- Cada cluster registrado com label `uniplus.io/managed=true`
- Cada componente (app ou platform)

E injeta **2 valueFiles**:
- `values.yaml` (defaults do chart)
- `environments/<environment>/values.yaml` (overrides do cluster)

Os dois ApplicationSets declaram `spec.goTemplate: true` + `goTemplateOptions: [missingkey=error]`. Sem isso o controller cai em fasttemplate e renderiza literais como `{{.app}}`, `{{.metadata.labels.environment}}` e a função Sprig `replace` — todos os Applications gerados colidem no mesmo nome e o AppSet falha com `ApplicationValidationError`. Manter ao adicionar generators ou trocar a sintaxe dos templates.

## Aplicação

Após o ArgoCD estar instalado:

```bash
# Registrar este cluster
argocd cluster add <context> --label uniplus.io/managed=true \
                              --label environment=standalone-compact

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

- Setup inicial do ArgoCD: `scripts/bootstrap-standalone.sh` (instala K3s + ArgoCD)
- Operação: [docs/RUNBOOKS.md](../docs/RUNBOOKS.md#12-deploy-de-mudança-via-gitops)
