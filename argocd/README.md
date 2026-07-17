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

- Permite os repositórios Git da org `unifesspa-edu-br` e os repositórios Helm
  upstream explicitamente usados pelos charts da plataforma
- Restringe destinos a este cluster
- Define roles RBAC (ctic-admin, developer)
- Bloqueia ResourceQuota/NetworkPolicy de virem do Git (gerenciados localmente)

### ApplicationSets

`applicationset.yaml` contém **2 ApplicationSets**:

1. **uniplus-apps** — gera Applications para os charts em `apps/`. Dois grupos:
   - **Sempre ligados** (todo cluster registrado): uniplus-web, uniplus-api-portal, uniplus-api-selecao, uniplus-api-ingresso, clamav-scanner, keycloak-replica, kafka-ui, apicurio-registry, redis-ui
   - **Habilitados só em ambientes específicos** (mecanismo por-ambiente, ver seção abaixo): uniplus-api-host, unifesspa-geo-api — hoje só em `hml-standalone-single`

2. **uniplus-platform** — gera Applications para componentes de plataforma:
   - storage, minio-console-proxy, traefik, cert-manager, external-secrets, vault, vault-transit, vault-transit-bootstrap
   - observability (prometheus, grafana, loki, tempo, otel-collector)

Cada ApplicationSet usa um ou mais **matrix generators** combinando:
- Cada cluster registrado com label `uniplus.io/managed=true`
- Cada componente (app ou platform) — no grupo sempre-ligado, incondicionalmente; no grupo seletivo de `uniplus-apps` (ver "Habilitação por-ambiente" abaixo), só para o(s) ambiente(s) declarado(s) por chart

E injeta **2 valueFiles**:
- `values.yaml` (defaults do chart)
- `environments/<environment>/values.yaml` (overrides do cluster)

Os dois ApplicationSets declaram `spec.goTemplate: true` + `goTemplateOptions: [missingkey=error]`. Sem isso o controller cai em fasttemplate e renderiza literais como `{{.app}}`, `{{.metadata.labels.environment}}` e a função Sprig `replace` — todos os Applications gerados colidem no mesmo nome e o AppSet falha com `ApplicationValidationError`. Manter ao adicionar generators ou trocar a sintaxe dos templates.

### Habilitação por-ambiente (quais charts existem em cada ambiente)

A maioria dos apps em `apps/` deve virar `Application` em **todo** cluster registrado — é o `matrix` (clusters × list) padrão descrito acima. Alguns charts, porém, só fazem sentido num subconjunto dos ambientes (ex.: um chart cuja imagem ainda não foi publicada em produção, ou que só existe para um ambiente de homologação). Registrá-lo incondicionalmente poluiria os demais ambientes com uma `Application` sem propósito ali.

O mecanismo — um segundo `matrix` generator dentro do MESMO ApplicationSet `uniplus-apps` — resolve isso sem hardcoded nenhum nome de chart na lógica de filtragem:

```yaml
- matrix:
    generators:
      # 1) o `list` PRECISA vir primeiro — ele produz `targetEnvironment`,
      #    consumido pelo generator seguinte. Matrix passa parâmetros de um
      #    generator filho para o próximo, mas só nesse sentido (produtor
      #    antes do consumidor).
      - list:
          elements:
            - app: uniplus-api-host
              namespace: uniplus
              targetEnvironment: hml-standalone-single
            - app: unifesspa-geo-api
              namespace: geo
              targetEnvironment: hml-standalone-single
      # 2) `clusters.selector.matchLabels` referencia `{{.targetEnvironment}}`
      #    do elemento acima — só o cluster com esse `environment` label
      #    sobrevive à combinação; nos demais, nenhuma Application nasce.
      - clusters:
          selector:
            matchLabels:
              uniplus.io/managed: "true"
              environment: '{{.targetEnvironment}}'
```

**Para habilitar um chart num ambiente:** adicionar um elemento `{app: <chart>, namespace: <namespace>, targetEnvironment: <ambiente>}` na `list`. **Para habilitar o mesmo chart em mais de um ambiente:** repetir o elemento trocando só o `targetEnvironment`. Nenhuma edição em `clusters`/`selector` é necessária — o padrão já é genérico para qualquer combinação chart×ambiente.

**`namespace` é obrigatório em todo elemento, dos dois grupos (sempre-ligado e seletivo).** `destination.namespace` do template é `'{{.namespace}}'`, não um literal — com `goTemplateOptions: [missingkey=error]`, esquecer o campo num elemento novo quebra a geração de **toda** a Application daquele elemento. A maioria dos charts compartilha o namespace `uniplus` (mesmo bounded context — portal/selecao/ingresso/host, web, platform de apoio); `unifesspa-geo-api` é a exceção: aplicação independente com bounded context próprio (só compartilha o emissor OIDC com as demais APIs), roda no namespace `geo`.

**Importante:** este mecanismo controla só se a `Application` é **gerada** pelo ArgoCD — não se o workload dentro dela está de fato ativo. Quando o chart tiver `<chart>.enabled: false` por padrão (caso de `uniplus-api-host`/`unifesspa-geo-api` hoje), uma `Application` gerada para um ambiente que não sobrescreve essa chave sincroniza com **zero recursos** (`Synced`/`Healthy`, sem `Deployment`/`Service`) até o ambiente ligar o chart explicitamente em `environments/<ambiente>/values.yaml`. O mesmo vale no sentido inverso — um chart cujo default seja `enabled: true` (caso de `uniplusWeb`) precisa de override explícito para `false` no ambiente que não deva rodá-lo ainda (é o que `hml-standalone-single` faz hoje com `uniplusWeb`, registrado no `matrix` sempre-ligado, mas desligado no overlay do ambiente). Em ambos os casos, habilitar a Application e habilitar o workload são duas decisões independentes.

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
