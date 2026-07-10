# environment lab-standalone-single

Values overlay de referência para a topologia de laboratório de host único
(K3s + Docker na mesma VM) — ver `../../scripts/lab-standalone-single/` para
os componentes stateful (Postgres, Redis, MinIO, Kafka) e a issue
[#395](https://github.com/unifesspa-edu-br/uniplus-infra/issues/395) para o
contexto completo da decomposição.

**Diferente do `standalone-compact`**: não há cluster ArgoCD registrado para
este ambiente — o `values.yaml` aqui é aplicado manualmente
(`helm install/upgrade -f environments/lab-standalone-single/values.yaml`)
durante a implementação das Tasks da issue #395, não via GitOps automático.
Cresce incrementalmente conforme cada componente de plataforma (Vault,
External Secrets Operator, ...) é validado.

## Componentes cobertos até o momento

| Componente | Chart | Notas |
|---|---|---|
| Vault | `platform/vault/` | Single-node (replicas=1), Shamir manual (1 key share, threshold 1 — simplificado para lab), sem peer PA1/OCI KMS |
| External Secrets Operator | `platform/external-secrets/` | `ClusterSecretStore vault-default` apontando para o Vault acima; NetworkPolicy habilitada nos dois charts (ver nota abaixo) |
| Secrets iniciais | `scripts/lab-standalone-single/seed-vault-secrets.sh` | Popula no Vault os paths que os charts de API/Keycloak esperam — ver seção própria abaixo |
| uniplus-api-portal | `apps/uniplus-api-portal/` | Deployable autônomo (ADR-0097 do `uniplus-api`); Kafka desligado (issue #423 — ver seção própria abaixo); módulo Portal ainda sem migrations de domínio no código (só schema `wolverine` de infraestrutura) |
| uniplus-api-host | `apps/uniplus-api-host/` | Composition root do monólito modular (Selecao+Ingresso+Configuracao+OrganizacaoInstitucional, ADR-0097 do `uniplus-api`); imagem buildada localmente (sem publish em GHCR ainda) — ver seção própria abaixo |

## Uso

```bash
helm dependency update platform/vault/
helm install vault platform/vault/ -f environments/lab-standalone-single/values.yaml --namespace vault
```

Após o primeiro install, inicializar e desselar manualmente:

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json
# custodiar a saída (unseal key + root token) fora do repo
kubectl exec -n vault vault-0 -- vault operator unseal <unseal_key>
```

Em seguida, habilitar o auth Kubernetes e criar a policy/role que o ESO usa
(procedimento completo em `platform/external-secrets/README.md`):

```bash
kubectl exec -n vault vault-0 -- sh -c '
  export VAULT_TOKEN=<root_token>
  vault auth enable kubernetes
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc.cluster.local
  vault policy write external-secrets-read - <<EOF
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read"] }
EOF
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-read \
    ttl=1h
  vault secrets enable -path=secret -version=2 kv
'
```

Depois, instalar o ESO — em duas etapas, porque os CRDs do subchart upstream
vêm como `templates/crds/*.yaml` normais (não a pasta especial `crds/` do
Helm), então não podem coexistir com o `ClusterSecretStore` (CR) no mesmo
`helm install` — o client resolve o kind antes de aplicar qualquer objeto:

```bash
helm dependency update platform/external-secrets/
kubectl create namespace external-secrets
# -f já na primeira instalação: sem isso, a NetworkPolicy do ESO nasce com
# os defaults do chart (kubeApiCidrs só com o service CIDR, sem o CIDR do
# host) e controller/webhook/cert-controller entram em CrashLoopBackOff
# antes mesmo do primeiro Ready (mesmo bug descrito abaixo). --set continua
# necessário para não colidir com o ClusterSecretStore (CRD ainda não existe).
helm install external-secrets platform/external-secrets/ -f environments/lab-standalone-single/values.yaml --namespace external-secrets --set clusterSecretStore.enabled=false
# aguardar os pods do ESO Ready, então:
helm upgrade external-secrets platform/external-secrets/ -f environments/lab-standalone-single/values.yaml --namespace external-secrets
```

### NetworkPolicy: kubeApiCidrs precisa do CIDR do host, não só do service CIDR

O k3s do lab embute o `kube-router` como NetworkPolicy controller mesmo
usando flannel como dataplane de pods — ele **enforça** NetworkPolicy, ao
contrário do que se supunha inicialmente. O egress ao Service `kubernetes`
(`10.43.0.1:443`) é avaliado **depois** do DNAT do kube-proxy: em K3s o
apiserver roda como processo no host (não como Pod), então o pacote de
saída já reescrito tem como destino `<ip-da-vm>:6443` — fora do CIDR de
serviço `10.43.0.0/16`. Sem o CIDR do host em `networkPolicy.kubeApiCidrs`,
o controller do ESO, o cert-controller e o webhook ficam em
`CrashLoopBackOff` com `dial tcp 10.43.0.1:443: connect: connection
refused` no `init()` (mesmo bug documentado em
`environments/standalone-compact/values.yaml`, ali com o CIDR da VCN OCI).

Como a chave raiz `networkPolicy` é compartilhada pelo `values.yaml` deste
environment entre os wrappers `platform/vault/` e `platform/external-secrets/`
(cada um lido via `-f` num `helm install/upgrade` separado), habilitá-la
afeta os dois charts — os defaults do chart Vault
(`externalSecretsNamespace: external-secrets`, `traefikNamespace: traefik`)
já batem com os nomes reais usados no lab, então não é necessário overridá-los
aqui.

## Secrets iniciais no Vault

Com Vault e ESO no ar, popular os paths que os charts `uniplus-api-*`
esperam (ver `apps/uniplus-api-*/values.yaml` chave
`externalSecrets.*.vaultPath`):

```bash
./scripts/lab-standalone-single/seed-vault-secrets.sh
```

O script sincroniza o Vault com as fontes de verdade já vivas na VM — nunca
gera segredo novo:

| Path | Origem |
|---|---|
| `secret/standalone/redis/default` | `$DATA_BASE/redis/.bootstrap-creds` (Task #406) |
| `secret/standalone/minio/root` | `$DATA_BASE/minio/.bootstrap-creds` (Task #407) |
| `secret/standalone/kafka/admin` | `$DATA_BASE/kafka/.bootstrap-creds` + `/etc/uniplus-kafka/certs/ca.crt` (Task #408) |
| `secret/standalone/keycloak/clients/uniplus-api-{selecao,portal,ingresso}` | `kcadm.sh get clients/.../client-secret` no pod `keycloak-replica` (clients M2M já existentes no realm, issue #163) |

**Não cobre** `secret/standalone/postgres/portal` — o role+db Postgres
dedicado só existe a partir da Task #413, populado dentro do procedimento
daquela Task, não aqui. Rodar o script de novo depois é seguro —
`vault kv put` é idempotente por natureza, sempre reflete a fonte de
verdade atual (útil inclusive para sincronizar após rotação de um
client_secret no Keycloak).

## uniplus-api-portal

A topologia real do backend não é "uma API por módulo de negócio" — ADR-0097
do `uniplus-api` (accepted 2026-06-26) define 3 executáveis: **Host**
(`Unifesspa.UniPlus.Host`, absorve Selecao+Ingresso+Configuracao+
OrganizacaoInstitucional como class libraries co-hospedadas, banco único
`uniplus` schema-por-módulo), **Geo** (`unifesspa-geo-api`, já deployável
autônomo) e **Portal** (`uniplus-api-portal`, também deployável autônomo,
banco próprio `uniplus_portal`). Só Portal e Geo têm chart Helm dedicado
neste repositório — Selecao/Ingresso/Configuracao/OrganizacaoInstitucional
são absorvidos pelo Host, que ainda não tem chart aqui (ver issue de
follow-up para criá-lo).

> **Pré-requisito:** `./scripts/lab-standalone-single/seed-vault-secrets.sh` já deve ter rodado com
> sucesso — o `ExternalSecret` desta API também referencia `secret/standalone/{redis/default,minio/root}`,
> não só o Postgres escrito abaixo. Esse script exige o Keycloak já deployado; numa VM nova,
> `seed-vault-secrets.sh` não roda sozinho dentro do `bootstrap.sh` por essa razão.
> `apps/keycloak-replica/` vem **desabilitado** por padrão e este `values.yaml` não liga
> `keycloak.enabled` nem `keycloak.networkPolicy.dataHostCIDR` (a guarda `fail` do template exige
> esse CIDR quando `networkPolicy.enabled=true`, default do chart. `KC_HOSTNAME_STRICT=true` também é
> default do chart, mas `hostname.url` vazio faz o Deployment omitir `KC_HOSTNAME` inteiro — sem
> hostname público neste lab, `hostname.strict=false` evita o Keycloak falhar validando um
> hostname que não existe):
>
> ```bash
> helm install keycloak-replica apps/keycloak-replica/ -f environments/lab-standalone-single/values.yaml \
>   --set keycloak.enabled=true \
>   --set keycloak.networkPolicy.dataHostCIDR=192.168.1.65/32 \
>   --set keycloak.database.host=192.168.1.65 \
>   --set keycloak.hostname.strict=false \
>   --namespace uniplus --create-namespace
> ```
>
> Além disso: role+database `keycloak` no Postgres e os secrets `secret/standalone/postgres/keycloak`
> e `secret/standalone/keycloak/admin` no Vault — nenhum dos dois é criado por `bootstrap.sh` nem
> `seed-vault-secrets.sh`; ver pré-requisitos completos em `apps/keycloak-replica/README.md`.

Pré-requisitos específicos desta API, feitos manualmente (não cobertos por
`seed-vault-secrets.sh`):

```bash
export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3 — sem isso, kubectl/helm bare falham com "permission denied"

# 1. Role + database dedicados no Postgres
sudo docker exec -i uniplus-postgres psql -U postgres <<SQL
CREATE ROLE portal WITH LOGIN PASSWORD '<senha gerada com openssl rand -hex 32>';
CREATE DATABASE uniplus_portal WITH OWNER = portal ENCODING = 'UTF8' LC_COLLATE = 'C.UTF-8' LC_CTYPE = 'C.UTF-8' TEMPLATE = template0;
SQL

# 2. A MESMA senha usada acima no Vault — vault CLI local via port-forward,
#    mesma higiene de credenciais do RUNBOOKS.md §8.4.3 (nunca token/senha
#    em argv; process substitution evita gravar a senha em disco)
kubectl -n vault port-forward vault-0 8200:8200 > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ROLE_PW' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done
read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN
read -rsp "Senha do role (a mesma do passo 1): " ROLE_PW; echo
vault kv put secret/standalone/postgres/portal password=@<(printf '%s' "$ROLE_PW")
kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ROLE_PW PF_PID  # sem exit — os passos 3-5 seguem no mesmo shell

# 3. Namespace uniplus (idempotente — não coberto pelo bootstrap.sh, que só
#    cria vault/external-secrets) + LocalKey de cifragem
#    (encryption.provider=local) — Secret K8s manual, não versionado; cada
#    environment gera a sua
kubectl create namespace uniplus --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic uniplus-api-portal-encryption-local \
  -n uniplus --from-literal=LOCAL_KEY="$(head -c 32 /dev/urandom | base64)"

# 4. Deploy
helm install uniplus-api-portal apps/uniplus-api-portal/ -f environments/lab-standalone-single/values.yaml --namespace uniplus
```

### Limitação conhecida: `/health` nunca fica `Healthy` com Kafka desligado (issue #423)

A API roda um `SchemaRegistrationHostedService` no boot que **exige** um
Schema Registry de fato alcançável quando `Kafka:BootstrapServers` está
populado (ADR-0051) — um placeholder sintático não basta, a aplicação
tenta registrar schemas de verdade e derruba o pod. Como o Apicurio
Registry não roda nesta leva do lab, `kafka.enabled: false`.

Efeito colateral: o SDK Confluent.Kafka ainda registra um producer ativo
mesmo sem `Kafka:BootstrapServers` configurado (cai no default
`localhost:9092`, loop de reconexão eterno), o que mantém o Kafka health
check dentro de `/health` (readiness, agregado) permanentemente
`Unhealthy` — mesmo com Postgres/Redis/MinIO/Keycloak saudáveis.
`/health/live` (dependency-free) responde `Healthy` normalmente, e é a
forma correta de confirmar que o processo está saudável no lab enquanto a
issue #423 não é resolvida. `readinessProbe` usa `/health` hardcoded no
`deployment.yaml` do chart — como o pod nunca fica `Ready`, um
`helm upgrade` que troque o pod trava em rollout (`RollingUpdate` espera
o novo pod ficar `Ready` antes de escalar o antigo para baixo); limpar
manualmente o ReplicaSet antigo (`kubectl delete replicaset <antigo>`) se
isso acontecer.

O módulo Portal ainda não tem entidades de domínio implementadas no
código — `dotnet ef` não gera migrations pendentes, então o banco fica só
com o schema `wolverine` (infraestrutura de mensageria:
outbox/inbox/dead-letters), sem tabelas de negócio. Isso é esperado (log
`Nenhuma migration EF Core pendente para PortalDbContext`), não uma falha
de configuração.

## uniplus-api-host

Composition root do monólito modular ([ADR-0097](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0097-topologia-de-deploy-em-tres-apis-monolito-modular.md)
do `uniplus-api`) — hospeda Selecao+Ingresso+Configuracao+OrganizacaoInstitucional
num único processo. Detalhes completos no `README.md` do chart
(`apps/uniplus-api-host/README.md`); resumo do procedimento específico do
lab abaixo.

> **Pré-requisito:** `./scripts/lab-standalone-single/seed-vault-secrets.sh` já deve ter rodado com
> sucesso — o `ExternalSecret` desta API também referencia `secret/standalone/{redis/default,minio/root}`,
> não só o Postgres escrito abaixo. Esse script exige o Keycloak já deployado; numa VM nova,
> `seed-vault-secrets.sh` não roda sozinho dentro do `bootstrap.sh` por essa razão.
> `apps/keycloak-replica/` vem **desabilitado** por padrão e este `values.yaml` não liga
> `keycloak.enabled` nem `keycloak.networkPolicy.dataHostCIDR` (a guarda `fail` do template exige
> esse CIDR quando `networkPolicy.enabled=true`, default do chart. `KC_HOSTNAME_STRICT=true` também é
> default do chart, mas `hostname.url` vazio faz o Deployment omitir `KC_HOSTNAME` inteiro — sem
> hostname público neste lab, `hostname.strict=false` evita o Keycloak falhar validando um
> hostname que não existe):
>
> ```bash
> helm install keycloak-replica apps/keycloak-replica/ -f environments/lab-standalone-single/values.yaml \
>   --set keycloak.enabled=true \
>   --set keycloak.networkPolicy.dataHostCIDR=192.168.1.65/32 \
>   --set keycloak.database.host=192.168.1.65 \
>   --set keycloak.hostname.strict=false \
>   --namespace uniplus --create-namespace
> ```
>
> Além disso: role+database `keycloak` no Postgres e os secrets `secret/standalone/postgres/keycloak`
> e `secret/standalone/keycloak/admin` no Vault — nenhum dos dois é criado por `bootstrap.sh` nem
> `seed-vault-secrets.sh`; ver pré-requisitos completos em `apps/keycloak-replica/README.md`.

```bash
export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3 — sem isso, kubectl/helm bare falham com "permission denied"

# 1. Role + database únicos no Postgres (banco compartilhado pelos 4 módulos)
sudo docker exec -i uniplus-postgres psql -U postgres <<SQL
CREATE ROLE uniplus WITH LOGIN PASSWORD '<senha gerada com openssl rand -hex 32>';
CREATE DATABASE uniplus WITH OWNER = uniplus ENCODING = 'UTF8' LC_COLLATE = 'C.UTF-8' LC_CTYPE = 'C.UTF-8' TEMPLATE = template0;
SQL

# 2. A MESMA senha usada acima no Vault — vault CLI local via port-forward,
#    mesma higiene de credenciais do RUNBOOKS.md §8.4.3 (nunca token/senha
#    em argv; process substitution evita gravar a senha em disco)
kubectl -n vault port-forward vault-0 8200:8200 > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ROLE_PW' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done
read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN
read -rsp "Senha do role (a mesma do passo 1): " ROLE_PW; echo
vault kv put secret/standalone/postgres/uniplus password=@<(printf '%s' "$ROLE_PW")
kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ROLE_PW PF_PID  # sem exit — os passos 3-5 seguem no mesmo shell

# 3. Namespace uniplus (idempotente — não coberto pelo bootstrap.sh, que só
#    cria vault/external-secrets) + LocalKey de cifragem — Secret K8s manual,
#    não versionado
kubectl create namespace uniplus --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic uniplus-api-host-encryption-local \
  -n uniplus --from-literal=LOCAL_KEY="$(head -c 32 /dev/urandom | base64)"

# 4. Build local da imagem (sem publish em GHCR ainda) + import no containerd
cd ../uniplus-api
docker build -f docker/Dockerfile.host -t uniplus-api-host:local-lab .
docker save uniplus-api-host:local-lab -o /tmp/uniplus-api-host.tar
scp /tmp/uniplus-api-host.tar uniplus@<ip-da-vm>:/tmp/
ssh uniplus@<ip-da-vm> "sudo k3s ctr images import /tmp/uniplus-api-host.tar"
cd ../uniplus-infra   # volta pro repo de infra antes do helm install (chart/values ficam aqui)

# 5. Deploy
helm install uniplus-api-host apps/uniplus-api-host/ -f environments/lab-standalone-single/values.yaml --namespace uniplus
```

Validado de ponta a ponta na VM de lab: pod `Running`/`1/1 Ready` já na
primeira tentativa (diferente do `uniplus-api-selecao` original, que nunca
ficava `Ready` com Kafka desligado por omissão de env var — ver seção
acima), `/health`, `/health/live` e `/health/ready` respondendo `Healthy`,
migrations EF Core aplicadas nos 4 schemas dedicados (`configuracao`: 15
tabelas, `selecao`: 20, `ingresso`: 5, `organizacao`: 5, além de
`wolverine`: 8), rotas `/api/organizacao/unidades` e `/api/configuracao/campi`
respondendo `200 []`.
