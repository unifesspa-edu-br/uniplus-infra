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
| uniplus-api-selecao | `apps/uniplus-api-selecao/` | Primeira das 3 APIs de negócio; Kafka desligado (issue #423 — ver seção própria abaixo) |

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

**Não cobre** `secret/standalone/postgres/{selecao,portal,ingresso}` — cada
role+db Postgres dedicado só existe a partir da Task que sobe a respectiva
API (#412/#413/#414); populado dentro do procedimento daquela Task, não
aqui. Rodar o script de novo depois é seguro — `vault kv put` é idempotente
por natureza, sempre reflete a fonte de verdade atual (útil inclusive para
sincronizar após rotação de um client_secret no Keycloak).

## uniplus-api-selecao

Pré-requisitos específicos desta API, feitos manualmente (não cobertos por
`seed-vault-secrets.sh`):

```bash
# 1. Role + database dedicados no Postgres
sudo docker exec -i uniplus-postgres psql -U postgres <<SQL
CREATE ROLE selecao WITH LOGIN PASSWORD '<senha gerada com openssl rand -hex 32>';
CREATE DATABASE uniplus_selecao WITH OWNER = selecao ENCODING = 'UTF8' LC_COLLATE = 'C.UTF-8' LC_CTYPE = 'C.UTF-8' TEMPLATE = template0;
SQL

# 2. A MESMA senha usada acima no Vault (path esperado pelo chart)
kubectl exec -n vault vault-0 -- vault kv put secret/standalone/postgres/selecao password=@<arquivo temporário, nunca argv>

# 3. LocalKey de cifragem (encryption.provider=local) — Secret K8s manual,
#    não versionado; cada environment gera a sua
kubectl create secret generic uniplus-api-selecao-encryption-local \
  -n uniplus --from-literal=LOCAL_KEY="$(head -c 32 /dev/urandom | base64)"

# 4. Deploy
helm install uniplus-api-selecao apps/uniplus-api-selecao/ -f environments/lab-standalone-single/values.yaml --namespace uniplus
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
