# Scripts do lab standalone-single (host combinado)

Topologia de **host único** para laboratório de validação — K3s + Docker no
mesmo host, diferente do `standalone-compact` real (2 VMs: `k8s-host` +
`data-host`, ver `../bootstrap-standalone.sh`). Complementar, não substitui:
o `standalone-compact` continua sendo a topologia de referência para
produção/homologação. Contexto completo na issue
[#395](https://github.com/unifesspa-edu-br/uniplus-infra/issues/395).

## `bootstrap.sh` — script consolidado

Orquestra Docker → K3s → Helm → Postgres → Redis → MinIO → Kafka → Vault →
External Secrets Operator num único comando idempotente, delegando para os
scripts individuais abaixo onde já existem. **Não cobre** o deploy das APIs
de negócio (`uniplus-api-host`/`uniplus-api-portal`) — cada uma depende de
artefatos externos a este repositório (build de imagem a partir do
`uniplus-api`, role+db Postgres dedicados) documentados nos READMEs de
`environments/lab-standalone-single/` e `apps/uniplus-api-{host,portal}/`.

```bash
sudo -v                                    # confirma sudo sem senha antes de rodar
cd /caminho/do/uniplus-infra               # precisa rodar de dentro do repo (usa platform/, environments/)
./scripts/lab-standalone-single/bootstrap.sh --dry-run
./scripts/lab-standalone-single/bootstrap.sh                  # execução real
./scripts/lab-standalone-single/bootstrap.sh --skip-platform  # só até Kafka, sem Vault/ESO
```

Validado de ponta a ponta na VM de lab (execução real, não só `--dry-run`):
todos os componentes já instalados/configurados são reconhecidos e
preservados sem reinício (idempotência), Vault e ESO atualizados via
`helm upgrade` sem downtime, secrets sincronizados no Vault com sucesso.

### `kubectl`/`helm` num host K3s recém-instalado

O instalador oficial do K3s cria `/usr/local/bin/{kubectl,ctr,crictl}` como
symlinks para o binário `k3s` unificado. Nesse modo, `kubectl` usa
`/etc/rancher/k3s/k3s.yaml` (`root:root 600`) como kubeconfig **default
nativo** — ignora `~/.kube/config` mesmo quando ele existe e está correto,
a menos que `KUBECONFIG` seja exportado explicitamente. `bootstrap.sh` já
faz isso (`export KUBECONFIG="$HOME/.kube/config"` logo no topo); scripts
futuros que chamem `kubectl`/`helm` neste host devem fazer o mesmo, ou
rodar com `sudo`.

## Scripts individuais

Cada um standalone e idempotente — replica fielmente o padrão de
`.bootstrap-creds` + systemd unit já usado no data-host real, adaptado
apenas em `DATA_HOST_IP` (aqui é o IP da própria VM, não de um host
externo). Podem ser rodados isoladamente para debugar/reaplicar um
componente específico sem repetir o fluxo completo do `bootstrap.sh`.

| Script | Função |
|--------|--------|
| `setup-redis.sh` | Redis 8.6.3 via Docker+systemd (ACL auth, persistência AOF+RDB) |
| `setup-minio.sh` | MinIO via Docker+systemd (SNSD single-node, buckets baseline) |
| `setup-kafka.sh` | Kafka 4.2.0 via Docker+systemd (KRaft combined, SASL_SSL + SCRAM-SHA-512, ADR-009) |
| `seed-vault-secrets.sh` | Popula no Vault os paths que os charts de API/Keycloak esperam |

Postgres não tem script próprio separado — o setup (systemd + LoadCredential,
mesmo padrão do `bootstrap-standalone.sh`, imagem `postgis/postgis:18-3.6`
em vez de `postgres:18-alpine` por causa do módulo Geo) vive dentro de
`bootstrap.sh` (`step_setup_postgres`), já que não havia necessidade de
reutilização isolada como os demais.

```bash
./setup-redis.sh                          # DATA_HOST_IP auto-detectado
DATA_HOST_IP=x.x.x.x ./setup-redis.sh      # override explícito
./setup-redis.sh --dry-run                 # mostra o que seria feito

./setup-minio.sh                          # idem, + cria buckets baseline
./setup-minio.sh --skip-buckets           # só sobe o serviço, sem tocar buckets

./setup-kafka.sh                          # gera certs TLS + format --add-scram na 1ª execução

./seed-vault-secrets.sh                    # sincroniza Vault com as fontes de verdade já vivas na VM
```

## Histórico

Os componentes deste diretório nasceram de validação manual (SSH ad-hoc) numa
VM de lab antes de serem formalizados como scripts versionados — ver a issue
`#395` e suas sub-issues para o rastreio completo da decomposição
(`bootstrap-standalone.sh` como referência de padrão de todo o repositório).
