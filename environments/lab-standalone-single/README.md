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
| Traefik | `platform/traefik/` | HTTPS autoassinado, único ingress controller do lab (substitui o Traefik embutido do k3s, desabilitado) — ver seção própria abaixo |
| apicurio-registry | `apps/apicurio-registry/` | Schema Registry (Confluent-compat) para uniplus-api-host/uniplus-api-portal (issue #423) — ver seção própria abaixo |
| uniplus-api-portal | `apps/uniplus-api-portal/` | Deployable autônomo (ADR-0097 do `uniplus-api`); Kafka+Schema Registry ligados desde a issue #423 — ver seção própria abaixo; módulo Portal ainda sem migrations de domínio no código (só schema `wolverine` de infraestrutura) |
| uniplus-api-host | `apps/uniplus-api-host/` | Composition root do monólito modular (Selecao+Ingresso+Configuracao+OrganizacaoInstitucional, ADR-0097 do `uniplus-api`); Kafka+Schema Registry ligados desde a issue #423; imagem buildada localmente (sem publish em GHCR ainda) — ver seção própria abaixo |
| uniplus-web | `apps/uniplus-web/` | 3 SPAs Angular (portal, selecao, ingresso), issue #432 — ver seção própria abaixo |

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
| `secret/standalone/keycloak/clients/uniplus-api-{selecao,portal,ingresso,host}` | `kcadm.sh get clients/.../client-secret` no pod `keycloak-replica` (clients M2M já existentes no realm — selecao/portal/ingresso desde a issue #163, host desde a issue #423) |

**Pré-requisito para o client `uniplus-api-host` (novo na issue #423): o
Keycloak precisa ter reconciliado o `uniplus-realm.json` atualizado.**
`--import-realm` do Keycloak só roda no primeiro boot — se o realm `uniplus`
já existe no banco (lab que já rodou `helm install keycloak-replica` antes
desta issue), um `helm upgrade` normal com o `uniplus-realm.json` atualizado
**não** cria o client novo, porque `keycloak.realmReconcile.enabled` é
`false` por padrão no chart e este `values.yaml` não liga a chave (mesma
lacuna documentada no RUNBOOKS.md sobre o `realm-reconcile-job`). Sem isso,
`seed-vault-secrets.sh` aborta em "client_secret de uniplus-api-host veio
vazio — client existe no realm uniplus?" **antes de escrever qualquer path
no Vault** (nem os dos outros 3 clients). Rodar antes, num lab que já tinha
Keycloak deployado:

```bash
helm upgrade keycloak-replica apps/keycloak-replica/ -f environments/lab-standalone-single/values.yaml \
  --set keycloak.enabled=true \
  --set keycloak.networkPolicy.enabled=false \
  --set keycloak.database.host=192.168.1.65 \
  --set keycloak.hostname.strict=false \
  --set keycloak.realmReconcile.enabled=true \
  --namespace uniplus \
  --wait --timeout=300s
```

Num lab **novo** (primeiro `helm install`, seção "uniplus-api-portal"
abaixo), o client já nasce junto no `--import-realm` inicial — este passo
extra não é necessário.

**Não cobre** `secret/standalone/postgres/portal` — o role+db Postgres
dedicado só existe a partir da Task #413, populado dentro do procedimento
daquela Task, não aqui. Rodar o script de novo depois é seguro —
`vault kv put` é idempotente por natureza, sempre reflete a fonte de
verdade atual (útil inclusive para sincronizar após rotação de um
client_secret no Keycloak).

## Traefik + TLS autoassinado

Issue #432. Todo acesso ao lab era via `kubectl exec`/`kubectl port-forward`
até então — funciona para health checks server-to-server, mas o
`uniplus-web` (SPA Angular) roda no **browser do usuário**: precisa de um
hostname de fato alcançável, **e HTTPS de verdade** — browsers só liberam a
Web Crypto API (necessária pro PKCE do `keycloak-js`) em *secure contexts*
(HTTPS ou `localhost`); `http://<host>`, mesmo em LAN privada, não
qualifica. Confirmado via Playwright: `window.isSecureContext=false`,
`crypto.subtle` indisponível, login trava com "Web Crypto API is not
available" mesmo com toda a infra saudável.

TLS real (Let's Encrypt via cert-manager) exigiria DNS público apontando
pro lab, que não existe — solução: certificado **autoassinado** cobrindo
`*.192.168.1.65.nip.io` ([nip.io](https://nip.io) resolve qualquer IP
embutido no hostname via DNS público, mesmo IP privado — a conexão TCP em
si continua sendo LAN-local; funciona tanto pra esta VM quanto pro browser
de quem estiver na mesma rede).

### k3s já vem com Traefik embutido — precisa desabilitar antes

K3s instala seu próprio Traefik por padrão (namespace `kube-system`,
`Service traefik` tipo `LoadBalancer` já mapeando a porta 80/443 da VM).
Conflita com `platform/traefik/` (mesma IngressClass, mesmos hostPorts) e,
mais importante, o objetivo do lab é validar **o chart real** do Uni+, não
o default do k3s. Desabilitar antes de instalar o nosso:

```bash
sudo mkdir -p /etc/rancher/k3s
printf 'disable:\n  - traefik\n' | sudo tee /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s
# aguardar ~15s — o addon-manager do k3s desinstala o Traefik embutido
# sozinho (jobs helm-delete-traefik*), sem precisar limpar nada manualmente
```

### Gerar o certificado autoassinado (uma vez, fora do Git)

```bash
openssl req -x509 -newkey rsa:2048 -nodes -keyout tls.key -out tls.crt -days 825 \
  -subj "/CN=uniplus-lab" \
  -addext "subjectAltName=DNS:*.192.168.1.65.nip.io,DNS:192.168.1.65.nip.io"

kubectl create secret tls uniplus-wildcard-nip-io-tls \
  --cert=tls.crt --key=tls.key -n uniplus
shred -u tls.crt tls.key   # a chave privada nunca entra no Git
```

A **parte pública** do certificado (não a chave) é reaproveitada como YAML
anchor `&labSelfSignedCA` no topo de `values.yaml` deste environment — ver
seção "Confiar no certificado autoassinado" abaixo.

### Deploy do Traefik

```bash
helm dependency update platform/traefik/
helm install traefik platform/traefik/ -f environments/lab-standalone-single/values.yaml \
  --namespace traefik --create-namespace --wait --timeout=180s
```

`ports.web.hostPort: 80` + `ports.websecure.hostPort: 443` bindam direto na
VM (via DNAT do CNI portmap plugin — não aparece em `ss -tlnp`, mas
funciona; confirmar com `curl` direto). `ports.web.http.redirections: null`
mantém a porta 80 servindo em paralelo (sem redirect forçado pra 443) —
útil para smoke tests via `curl` sem `-k`/`-v` que não precisam de secure
context.

### Confiar no certificado autoassinado (server-to-server)

Chamadas server-to-server que validam o `iss` claim de tokens do Keycloak
(Host/Portal validando bearer tokens, Apicurio validando tokens ao
registrar schema) **também precisam confiar no certificado** — não só o
browser. Dois mecanismos diferentes, por runtime:

- **.NET** (`uniplus-api-host`, `uniplus-api-portal`, `unifesspa-geo-api`):
  `SSL_CERT_FILE`/`SSL_CERT_DIR` **não funcionam** — funcionam para
  `curl`/libcurl (que lê essas env vars via OpenSSL), mas o runtime .NET no
  Linux só confia no bundle do sistema
  (`/etc/ssl/certs/ca-certificates.crt`). Solução: `customCA.enabled: true`
  nos 3 charts — um `initContainer` roda `update-ca-certificates` de
  verdade (mesma imagem da app, tem a ferramenta; roda como root só ali,
  container principal continua non-root) e compartilha o bundle atualizado
  via `emptyDir` montado em `/etc/ssl/certs` no container principal. Ver
  comentário completo em `apps/uniplus-api-host/values.yaml` `customCA`.
- **Quarkus/Java** (`apicurio-registry`): `extraEnv: QUARKUS_TLS_TRUST_ALL=true`
  (registro de TLS unificado — a propriedade antiga
  `QUARKUS_OIDC_TLS_TRUST_ALL` foi testada primeiro e **não funcionou**
  nesta versão do Quarkus/Apicurio). `trust-all` só é aceitável porque é
  cert autoassinado de lab — nunca usar em produção real.

### Hostnames deste lab

| Serviço | Hostname |
|---|---|
| Keycloak | `keycloak.192.168.1.65.nip.io` |
| Apicurio Registry | `apicurio.192.168.1.65.nip.io` |
| uniplus-api-host | `api-host.192.168.1.65.nip.io` |
| uniplus-api-portal | `api-portal.192.168.1.65.nip.io` |
| unifesspa-geo-api | `api-geo.192.168.1.65.nip.io` |
| uniplus-web (portal) | `portal.192.168.1.65.nip.io` |
| uniplus-web (selecao) | `selecao.192.168.1.65.nip.io` |
| uniplus-web (ingresso) | `ingresso.192.168.1.65.nip.io` |

### Gotcha: NetworkPolicy de egress com hostPort — DNAT acontece antes da avaliação

Ao religar `apicurioRegistry.networkPolicy.enabled: true` (agora que
Traefik existe de verdade), a regra de egress `oidcIssuerCIDR:
192.168.1.65/32` (apontando pro IP da VM, porta 443) **nunca batia** —
`Connection refused` do pod do Apicurio para `keycloak.192.168.1.65.nip.io`,
apesar de um `curl` direto de outro pod (sem NetworkPolicy própria)
funcionar normalmente. Causa: o `hostPort` do Traefik é implementado via
DNAT (CNI portmap, `iptables -t nat`), e o `kube-router` (NetworkPolicy
controller do k3s) avalia egress **depois** do DNAT — o destino real
pós-DNAT é o IP do **pod** do Traefik (`10.42.0.x`), não o IP da VM (mesma
classe de bug já documentada para o Service `kubernetes` do apiserver, ver
seção "NetworkPolicy: kubeApiCidrs" acima, aqui via hostPort em vez de
kube-proxy). Fix: `oidcIssuerCIDR: 10.42.0.0/16` (pod CIDR do cluster) +
`oidcIssuerPort: 8443` (containerPort real do entryPoint `websecure` do
Traefik, não a porta externa 443).

## Apicurio Registry

Schema Registry (Confluent-compat) consumido por `uniplus-api-host` e
`uniplus-api-portal` para registrar/validar schemas Avro dos eventos Kafka
(ADR-0051 do `uniplus-api`). Chart de referência já validado em produção
(`environments/standalone-compact/values.yaml`) — no lab, adaptado para o
Traefik + TLS autoassinado da issue #432 (seção própria acima).

> **Pré-requisito:** `./scripts/lab-standalone-single/seed-vault-secrets.sh`
> e o Keycloak já devem estar no ar (mesmos pré-requisitos das APIs abaixo).

```bash
export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3

# 1. Role + database dedicados no Postgres
sudo docker exec -i uniplus-postgres psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE ROLE apicurio WITH LOGIN PASSWORD '<senha gerada com openssl rand -hex 32>';
CREATE DATABASE apicurio WITH OWNER = apicurio ENCODING = 'UTF8' LC_COLLATE = 'C.UTF-8' LC_CTYPE = 'C.UTF-8' TEMPLATE = template0;
SQL

# 2. A MESMA senha usada acima, no Vault — vault CLI local via port-forward,
#    mesma higiene de credenciais do RUNBOOKS.md §8.4.3
kubectl -n vault port-forward vault-0 8200:8200 > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ROLE_PW' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done
read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN
read -rsp "Senha do role (a mesma do passo 1): " ROLE_PW; echo
vault kv put secret/standalone/postgres/apicurio username=apicurio password=@<(printf '%s' "$ROLE_PW")

# 3. client_secret do client "apicurio-registry" (já existe no realm.json
#    desde a issue #152) — recuperar via kcadm dentro do próprio pod do
#    Keycloak. Senha via stdin (sh -c de aspas simples, sem interpolação
#    local) — nunca em argv local nem do pod.
KC_ADMIN_PW=$(vault kv get -field=password secret/standalone/keycloak/admin)
printf '%s' "$KC_ADMIN_PW" | kubectl exec -i -n uniplus deploy/keycloak-replica -- sh -c '
  read -r ADMIN_PW
  /opt/keycloak/bin/kcadm.sh config credentials --server http://localhost:8080/auth \
    --realm master --user admin --password "$ADMIN_PW"
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=apicurio-registry --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r uniplus --fields value --format csv --noquotes
' | tail -1 > /tmp/apicurio-cs
vault kv put secret/standalone/keycloak/clients/apicurio-registry client_secret=@/tmp/apicurio-cs
shred -u /tmp/apicurio-cs
kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ROLE_PW PF_PID KC_ADMIN_PW  # sem exit — o passo 4 segue no mesmo shell

# 4. Deploy
helm install apicurio-registry apps/apicurio-registry/ -f environments/lab-standalone-single/values.yaml --namespace uniplus --wait --timeout=120s

# 5. Validar (readinessProbe real do chart — Apicurio 3.2.4 desabilita /q/health/*)
kubectl exec -n uniplus deploy/apicurio-registry-apicurio-registry -- curl -s http://localhost:8080/apis/registry/v3/system/info
```

### NetworkPolicy: ingress só libera o namespace Traefik — religada na issue #432

O template `apps/apicurio-registry/templates/networkpolicy.yaml` só libera
ingress na porta 8080 para pods do namespace `traefik` (produção: todo
tráfego HTTP ao Apicurio, mesmo vindo de outro Pod do mesmo cluster, passa
pelo Traefik — `schemaRegistry.url` em `standalone-compact` aponta para o
hostname público, não para o Service ClusterIP). Na issue #423 este lab
ainda não tinha Traefik, então a policy ficava `enabled: false`
(`uniplus-api-host`/`uniplus-api-portal` nunca bateriam no allow-list —
`Connection refused` no boot do `SchemaRegistrationHostedService`). Desde a
issue #432 o Traefik existe de fato (seção acima) — a policy volta a
`enabled: true`, `schemaRegistry.url`/`oidc.issuerUri` do Host/Portal agora
apontam pro hostname do Traefik (`apicurio.192.168.1.65.nip.io`,
`keycloak.192.168.1.65.nip.io`) em vez do Service ClusterIP direto, igual
à produção real. Ver também o gotcha de NetworkPolicy+hostPort+DNAT na
seção "Traefik + TLS autoassinado" acima — `oidcIssuerCIDR`/`oidcIssuerPort`
não apontam pro IP da VM, e sim pro pod CIDR + porta interna do Traefik.

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

> **Pré-requisito:** HashiCorp `vault` CLI instalada na VM (`bootstrap.sh` só deploya o servidor via
> Helm — o binário local não vem com ele; pacote oficial ou `apt install vault` via repositório
> HashiCorp). Os passos abaixo usam essa CLI local + port-forward (mesma higiene de credenciais do
> RUNBOOKS.md §8.4.3), nunca `kubectl exec` com segredo em argv.

> **Pré-requisito:** `./scripts/lab-standalone-single/seed-vault-secrets.sh` já deve ter rodado com
> sucesso — o `ExternalSecret` desta API também referencia `secret/standalone/{redis/default,minio/root}`,
> não só o Postgres escrito abaixo. Esse script exige o Keycloak já deployado; numa VM nova,
> `seed-vault-secrets.sh` não roda sozinho dentro do `bootstrap.sh` por essa razão.
> `apps/keycloak-replica/` vem **desabilitado** por padrão e este `values.yaml` não liga
> `keycloak.enabled`. `networkPolicy.enabled=true` é default do chart — sem `dataHostCIDR` (não
> setado neste environment) o `fail` do template bloqueia o render. **Desde a issue #432** o
> Traefik existe de verdade no lab (seção "Traefik + TLS autoassinado" acima), então a policy
> fica **religada** (`networkPolicy.enabled=true`, ingress via `keycloak.192.168.1.65.nip.io`) em
> vez do antigo `networkPolicy.enabled=false` (workaround só pela ausência de Traefik). `hostname.url`
> aponta pro hostname do Traefik (`https://keycloak.192.168.1.65.nip.io/auth`) — precisa bater com
> o que o browser bate, senão o `iss` claim dos tokens não confere com o esperado pelos clients.
> Role+database `keycloak` no Postgres e os secrets
> `secret/standalone/postgres/keycloak`/`secret/standalone/keycloak/admin` no Vault também não são
> criados por `bootstrap.sh` nem `seed-vault-secrets.sh` — o `ExternalSecret` do chart consome os
> dois via `envFrom` (ver pré-requisitos completos em `apps/keycloak-replica/README.md`):
>
> ```bash
> export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3 — sem isso, kubectl/helm bare falham com "permission denied"
>
> # 0a. Role + database do Keycloak no Postgres
> sudo docker exec -i uniplus-postgres psql -U postgres -v ON_ERROR_STOP=1 <<SQL
> CREATE ROLE keycloak WITH LOGIN PASSWORD '<senha gerada com openssl rand -hex 32>';
> CREATE DATABASE keycloak WITH OWNER = keycloak ENCODING = 'UTF8' LC_COLLATE = 'C.UTF-8' LC_CTYPE = 'C.UTF-8' TEMPLATE = template0;
> SQL
>
> # 0b. Secrets do Keycloak no Vault — mesma higiene de credenciais da §8.4.3 do RUNBOOKS.md
> kubectl -n vault port-forward vault-0 8200:8200 > /tmp/vault-pf.log 2>&1 &
> PF_PID=$!
> trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR' EXIT
> export VAULT_ADDR=http://127.0.0.1:8200
> until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done
> read -rsp "Root token: " VAULT_TOKEN; echo
> export VAULT_TOKEN
> read -rsp "Senha do role keycloak (a mesma do passo 0a): " KC_DB_PW; echo
> vault kv put secret/standalone/postgres/keycloak host=192.168.1.65 port=5432 database=keycloak username=keycloak password=@<(printf '%s' "$KC_DB_PW")
> read -rsp "Senha do admin bootstrap do Keycloak (nova, escolha do operador): " KC_ADMIN_PW; echo
> vault kv put secret/standalone/keycloak/admin username=admin password=@<(printf '%s' "$KC_ADMIN_PW")
> kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR KC_DB_PW KC_ADMIN_PW PF_PID
>
> # 0c. Deploy — repassando TODOS os --set que o release já usava (não só o
> # novo), senão helm upgrade reverte silenciosamente aos defaults do chart
> # tudo que ficou de fora (lição da regressão de NetworkPolicy da Epic #395)
> helm install keycloak-replica apps/keycloak-replica/ -f environments/lab-standalone-single/values.yaml \
>   --set keycloak.enabled=true \
>   --set keycloak.database.host=192.168.1.65 \
>   --set keycloak.hostname.strict=false \
>   --set keycloak.realmReconcile.enabled=true \
>   --namespace uniplus --create-namespace \
>   --wait --timeout=300s
> ```

Pré-requisitos específicos desta API, feitos manualmente (não cobertos por
`seed-vault-secrets.sh`):

```bash
export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3 — sem isso, kubectl/helm bare falham com "permission denied"

# 1. Role + database dedicados no Postgres
sudo docker exec -i uniplus-postgres psql -U postgres -v ON_ERROR_STOP=1 <<SQL
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

### Kafka + Schema Registry ligados desde a issue #423

A API roda um `SchemaRegistrationHostedService` no boot que **exige** um
Schema Registry de fato alcançável quando `Kafka:BootstrapServers` está
populado (ADR-0051) — um placeholder sintático não basta, a aplicação
tenta registrar schemas de verdade e derruba o pod. Antes da issue #423 o
Apicurio Registry não rodava no lab, então o Portal subia com
`kafka.enabled: false` — mas o template do chart **omitia** por completo a
env var `Kafka__BootstrapServers` nesse caso (em vez de renderizá-la sempre
com um valor "vazio" reconhecido pelo SDK), fazendo o Confluent.Kafka cair
no default `localhost:9092` e entrar em loop de reconexão eterno: o Kafka
health check dentro de `/health` (readiness, agregado) ficava
permanentemente `Unhealthy` mesmo com Postgres/Redis/MinIO/Keycloak
saudáveis (mesmo bug já corrigido antes no `uniplus-api-host` — ver
RUNBOOKS.md §20.3).

Corrigido na issue #423 em duas frentes: (1) o template do chart passou a
renderizar `Kafka__BootstrapServers` sempre — valor real quando ligado, `" "`
(um espaço, `string.IsNullOrWhiteSpace=true`) quando desligado, mesmo padrão
do `uniplus-api-host`; (2) o Apicurio Registry passou a rodar no lab (seção
própria acima), permitindo religar `kafka.enabled: true` de fato. `/health`
confirmado `Healthy` no Portal com Kafka+Schema Registry ligados.

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

> **Pré-requisito:** HashiCorp `vault` CLI instalada na VM (`bootstrap.sh` só deploya o servidor via
> Helm — o binário local não vem com ele; pacote oficial ou `apt install vault` via repositório
> HashiCorp). Os passos abaixo usam essa CLI local + port-forward (mesma higiene de credenciais do
> RUNBOOKS.md §8.4.3), nunca `kubectl exec` com segredo em argv.

> **Pré-requisito:** `./scripts/lab-standalone-single/seed-vault-secrets.sh` já deve ter rodado com
> sucesso — o `ExternalSecret` desta API também referencia `secret/standalone/{redis/default,minio/root}`,
> não só o Postgres escrito abaixo. Esse script exige o Keycloak já deployado; numa VM nova,
> `seed-vault-secrets.sh` não roda sozinho dentro do `bootstrap.sh` por essa razão.
> `apps/keycloak-replica/` vem **desabilitado** por padrão e este `values.yaml` não liga
> `keycloak.enabled`. `networkPolicy.enabled=true` é default do chart — sem `dataHostCIDR` (não
> setado neste environment) o `fail` do template bloqueia o render. **Desde a issue #432** o
> Traefik existe de verdade no lab (seção "Traefik + TLS autoassinado" acima), então a policy
> fica **religada** (`networkPolicy.enabled=true`, ingress via `keycloak.192.168.1.65.nip.io`) em
> vez do antigo `networkPolicy.enabled=false` (workaround só pela ausência de Traefik). `hostname.url`
> aponta pro hostname do Traefik (`https://keycloak.192.168.1.65.nip.io/auth`) — precisa bater com
> o que o browser bate, senão o `iss` claim dos tokens não confere com o esperado pelos clients.
> Role+database `keycloak` no Postgres e os secrets
> `secret/standalone/postgres/keycloak`/`secret/standalone/keycloak/admin` no Vault também não são
> criados por `bootstrap.sh` nem `seed-vault-secrets.sh` — o `ExternalSecret` do chart consome os
> dois via `envFrom` (ver pré-requisitos completos em `apps/keycloak-replica/README.md`):
>
> ```bash
> export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3 — sem isso, kubectl/helm bare falham com "permission denied"
>
> # 0a. Role + database do Keycloak no Postgres
> sudo docker exec -i uniplus-postgres psql -U postgres -v ON_ERROR_STOP=1 <<SQL
> CREATE ROLE keycloak WITH LOGIN PASSWORD '<senha gerada com openssl rand -hex 32>';
> CREATE DATABASE keycloak WITH OWNER = keycloak ENCODING = 'UTF8' LC_COLLATE = 'C.UTF-8' LC_CTYPE = 'C.UTF-8' TEMPLATE = template0;
> SQL
>
> # 0b. Secrets do Keycloak no Vault — mesma higiene de credenciais da §8.4.3 do RUNBOOKS.md
> kubectl -n vault port-forward vault-0 8200:8200 > /tmp/vault-pf.log 2>&1 &
> PF_PID=$!
> trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR' EXIT
> export VAULT_ADDR=http://127.0.0.1:8200
> until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done
> read -rsp "Root token: " VAULT_TOKEN; echo
> export VAULT_TOKEN
> read -rsp "Senha do role keycloak (a mesma do passo 0a): " KC_DB_PW; echo
> vault kv put secret/standalone/postgres/keycloak host=192.168.1.65 port=5432 database=keycloak username=keycloak password=@<(printf '%s' "$KC_DB_PW")
> read -rsp "Senha do admin bootstrap do Keycloak (nova, escolha do operador): " KC_ADMIN_PW; echo
> vault kv put secret/standalone/keycloak/admin username=admin password=@<(printf '%s' "$KC_ADMIN_PW")
> kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR KC_DB_PW KC_ADMIN_PW PF_PID
>
> # 0c. Deploy — repassando TODOS os --set que o release já usava (não só o
> # novo), senão helm upgrade reverte silenciosamente aos defaults do chart
> # tudo que ficou de fora (lição da regressão de NetworkPolicy da Epic #395)
> helm install keycloak-replica apps/keycloak-replica/ -f environments/lab-standalone-single/values.yaml \
>   --set keycloak.enabled=true \
>   --set keycloak.database.host=192.168.1.65 \
>   --set keycloak.hostname.strict=false \
>   --set keycloak.realmReconcile.enabled=true \
>   --namespace uniplus --create-namespace \
>   --wait --timeout=300s
> ```

```bash
export KUBECONFIG="$HOME/.kube/config"   # ver RUNBOOKS.md §20.3 — sem isso, kubectl/helm bare falham com "permission denied"

# 1. Role + database únicos no Postgres (banco compartilhado pelos 4 módulos)
sudo docker exec -i uniplus-postgres psql -U postgres -v ON_ERROR_STOP=1 <<SQL
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

Validado de ponta a ponta na VM de lab: pod `Running`/`1/1 Ready`,
`/health`, `/health/live` e `/health/ready` respondendo `Healthy`,
migrations EF Core aplicadas nos 4 schemas dedicados (`configuracao`: 15
tabelas, `selecao`: 20, `ingresso`: 5, `organizacao`: 5, além de
`wolverine`: 8), rotas `/api/organizacao/unidades` e `/api/configuracao/campi`
respondendo `200 []`.

Kafka + Schema Registry ligados desde a issue #423 (ver seção "Apicurio
Registry" acima): `SchemaRegistrationHostedService` registra o schema Avro
do módulo Selecao (`processo_seletivo_events-value`) no Apicurio no boot e
o Wolverine `KafkaTransport` cria o tópico correspondente — confirmado nos
logs do pod. `schemaRegistry.url`/`oidc.issuerUri` apontam pro hostname do
Traefik (issue #432) — `apicurioRegistry.networkPolicy`/`keycloak.networkPolicy`
voltaram a `enabled: true`, e o Host precisa confiar no certificado
autoassinado (`customCA.enabled: true`) pra validar o JWKS via HTTPS — ver
seção "Traefik + TLS autoassinado" acima pros dois gotchas reais
encontrados (DNAT+NetworkPolicy, SSL_CERT_FILE não funciona pro .NET).

## uniplus-web

Issue #432. 3 SPAs Angular (portal, selecao, ingresso) — 1 chart, 1
Deployment por app, imagens já publicadas em GHCR (`v0.2.1`, confirmadas
pull-áveis via `docker manifest inspect`) — sem build local necessário,
diferente do `uniplus-api-host`.

> **Pré-requisito:** Traefik + TLS autoassinado + os 5 backends (Keycloak,
> Apicurio, Host, Portal, Geo API) já no ar (seções acima). O client OIDC
> público `uniplus-portal` (compartilhado pelas 3 SPAs) precisa existir no
> realm — ver `keycloak.realmImport.portalClient` no `values.yaml` deste
> environment.

```bash
export KUBECONFIG="$HOME/.kube/config"

helm install uniplus-web apps/uniplus-web/ -f environments/lab-standalone-single/values.yaml \
  --namespace uniplus --wait --timeout=180s
```

`ingress.tls.certManager.enabled` **precisa** ser explicitamente `false`
neste `values.yaml` — ao contrário dos outros charts (default `false`), o
default do `uniplus-web` é `certManager.enabled: true` (produção real usa
Let's Encrypt); sem o override, o `helm upgrade` falha com
`no matches for kind "Certificate" in version "cert-manager.io/v1"`
(CRD inexistente no lab).

### Validação: login OIDC real via browser (Playwright)

Confirmado ponta a ponta com um browser de verdade (não só `curl`), usando
um usuário de teste temporário criado via `kcadm.sh` e removido depois:

1. `https://portal.192.168.1.65.nip.io/` carrega sem erro de Web Crypto
   (`window.isSecureContext === true`, `crypto.subtle` disponível).
2. Clicar em rota protegida ("Meu Perfil") redireciona pro Keycloak com
   `code_challenge`/`code_challenge_method=S256` (PKCE gerado client-side
   de verdade) e `redirect_uri` batendo com o registrado no client.
3. Login com usuário/senha → tela de completar perfil (primeiro acesso) →
   redirect de volta pro `redirect_uri` com o `code`.
4. SPA troca o `code` pelo token (via `fragment` response mode) e mostra o
   nome do usuário logado no cabeçalho — sessão autenticada confirmada.

Nota sobre Playwright especificamente: o browser headless rejeita o
certificado autoassinado por padrão (`net::ERR_CERT_AUTHORITY_INVALID`,
igual a um usuário real veria um aviso antes de "Avançar mesmo assim") —
contornado via CDP (`Security.setIgnoreCertificateErrors`), não uma
limitação do fix em si.
