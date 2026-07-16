# uniplus-api-host

API .NET 10 — composition root do monólito modular Uni+.

## Visão geral

Segundo [ADR-0097](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0097-topologia-de-deploy-em-tres-apis-monolito-modular.md)
do repositório `uniplus-api` (accepted 2026-06-26), a topologia real do
backend Uni+ **não é** "uma API por módulo de negócio". São 3 executáveis:

- **Host** (este chart) — composition root (`Unifesspa.UniPlus.Host`) que
  hospeda os módulos internos **Selecao + Ingresso + Configuracao +
  OrganizacaoInstitucional** como class libraries co-hospedadas num único
  processo. Banco Postgres único `uniplus` com schema-por-módulo
  (`HasDefaultSchema`) + schema `wolverine` para o outbox. Uma única
  instância de Wolverine serve os 4 módulos.
- **Geo** (`apps/unifesspa-geo-api/`) — deployable autônomo, banco próprio.
- **Portal** (`apps/uniplus-api-portal/`) — deployable autônomo, banco próprio.

Os charts `apps/uniplus-api-{selecao,ingresso}/` representavam a topologia
anterior (uma imagem por módulo), abandonada pelo ADR-0097.

## Pré-requisitos

| Recurso | De onde vem |
|---|---|
| Role + database Postgres únicos (`uniplus`/`uniplus`) | Custódia manual — ver `environments/lab-standalone-single/README.md` |
| Senha do role no Vault | `secret/standalone/postgres/uniplus` |
| Vault + External Secrets Operator | `platform/vault/` + `platform/external-secrets/` |
| `UniPlus__Encryption__LocalKey` (quando `encryption.provider=local`) | Secret K8s manual, não versionado — ver `extraEnv` no values.yaml do environment |

## Kafka: sempre `Kafka__BootstrapServers` setado, nunca omitido

Diferente dos charts `uniplus-api-{selecao,portal}` (que omitem a env var
inteira via `{{- if kafka.enabled }}` quando desligado), este chart
**sempre** renderiza `Kafka__BootstrapServers` — com o valor real quando
`kafka.enabled=true`, ou `" "` (um espaço) quando `false`.

O host consulta essa configuração em dois pontos independentes do
`uniplus-api` (`Infrastructure.Core/Messaging/WolverineOutboxConfiguration.cs`
e `Selecao.API/SelecaoMessagingRegistration.cs`), ambos via
`string.IsNullOrWhiteSpace` — que trata `" "` como "vazio", desligando o
transporte Kafka de forma limpa sem disparar a validação fatal
`"Kafka:BootstrapServers populado mas SchemaRegistry:Url vazio"` (ADR-0051
do uniplus-api). Mesma receita documentada em
`uniplus-api/docker/docker-compose.monolito.yml`.

Omitir a env var por completo (o padrão dos outros 2 charts) **não é
equivalente** aqui — descoberto por bug real durante a Task uniplus-infra#412
(revertida): sem a env var setada, o SDK Confluent.Kafka cai no default
`localhost:9092` e fica em loop de reconexão eterno, mantendo `/health`
(readiness) permanentemente `Unhealthy` mesmo com o transporte Wolverine
desligado.

## Imagem: sem publish em GHCR ainda

O pipeline `publish-images.yml` do `uniplus-api` só dispara em tags
`v*.*.*` — nenhuma foi criada para o módulo `host` até o momento. Publicar
uma teria efeito real em produção (release pública), fora do escopo de
uma Task de lab.

Para o lab, a imagem é buildada localmente e importada direto no
containerd do k3s (sem passar por um registry):

```bash
cd ../uniplus-api  # repositório uniplus-api clonado lado a lado
docker build -f docker/Dockerfile.host -t uniplus-api-host:local-lab .
docker save uniplus-api-host:local-lab -o /tmp/uniplus-api-host.tar
scp /tmp/uniplus-api-host.tar uniplus@<ip-da-vm>:/tmp/
ssh uniplus@<ip-da-vm> "sudo k3s ctr images import /tmp/uniplus-api-host.tar"
```

`environments/lab-standalone-single/values.yaml` aponta
`image.registry: docker.io/library`, `image.tag: local-lab`,
`pullPolicy: Never` — sem `Never`, o kubelet tentaria puxar de um registry
remoto inexistente mesmo com a imagem já presente localmente.

Quando o pipeline publicar a primeira release real (`ghcr.io/unifesspa-edu-br/uniplus-api-host`),
atualizar `image.registry`/`image.repository`/`image.tag`/`pullPolicy` no
environment e remover o build local.

## Roteamento path-based

Para expor o Host junto de outras APIs sob o mesmo FQDN, configure
`uniplusApiHost.ingress.pathPrefixes`. Cada item cria uma rota Traefik
`Host() && PathPrefix()` apontando para este mesmo Service, sem middleware de
`StripPrefix`: os controllers do Host recebem o caminho completo.

```yaml
uniplusApiHost:
  ingress:
    enabled: true
    host: uniplus-api-hml.192.168.21.134.nip.io
    pathPrefixes:
      - /api/selecao
      - /api/ingresso
      - /api/publicacoes
      - /api/auth
      - /api/profile
      - /openapi
```

`pathPrefixes` é opcional. Quando a lista está vazia ou ausente, o chart
mantém a rota `Host()` pura usada pelos ambientes existentes. Os prefixos
`/api/auth`, `/api/profile` e `/openapi` também pertencem ao Host e devem ser
incluídos quando forem expostos no mesmo domínio.

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `uniplusApiHost.database.name`/`username` | `uniplus`/`uniplus` | Banco único — 6 connection strings (`UniPlusDb`, `ConfiguracaoDb`, `OrganizacaoDb`, `SelecaoDb`, `IngressoDb`, `PublicacoesDb`) apontam todas para cá |
| `uniplusApiHost.kafka.enabled` | `false` | Desligado até o Apicurio Registry entrar no lab (issue #423) |
| `uniplusApiHost.schemaRegistry.url` | `""` | Feature off; ver bloco Kafka acima |
| `uniplusApiHost.oidc.enabled` | `true` | Bearer validation apenas — o Host não se autentica como client M2M contra nada |
| `uniplusApiHost.ingress.pathPrefixes` | `[]` | Lista opcional de subpaths do Host. Cada item gera `Host() && PathPrefix()` sem `StripPrefix`; vazia mantém `Host()` puro |
