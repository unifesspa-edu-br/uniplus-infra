# Scripts do lab standalone-single (host combinado)

Topologia de **host único** para laboratório de validação — K3s + Docker no
mesmo host, diferente do `standalone-compact` real (2 VMs: `k8s-host` +
`data-host`, ver `../bootstrap-standalone.sh`). Complementar, não substitui:
o `standalone-compact` continua sendo a topologia de referência para
produção/homologação. Contexto completo na issue
[#395](https://github.com/unifesspa-edu-br/uniplus-infra/issues/395).

Cada script abaixo é standalone e idempotente — replica fielmente o padrão
de `.bootstrap-creds` + systemd unit já usado no data-host real, adaptado
apenas em `DATA_HOST_IP` (aqui é o IP da própria VM, não de um host externo).

| Script | Função |
|--------|--------|
| `setup-redis.sh` | Redis 8.6.3 via Docker+systemd (ACL auth, persistência AOF+RDB) |
| `setup-minio.sh` | MinIO via Docker+systemd (SNSD single-node, buckets baseline) |

## Uso

```bash
./setup-redis.sh                          # DATA_HOST_IP auto-detectado
DATA_HOST_IP=x.x.x.x ./setup-redis.sh      # override explícito
./setup-redis.sh --dry-run                 # mostra o que seria feito

./setup-minio.sh                          # idem, + cria buckets baseline
./setup-minio.sh --skip-buckets           # só sobe o serviço, sem tocar buckets
```

## Histórico

Os componentes deste diretório nasceram de validação manual (SSH ad-hoc) numa
VM de lab antes de serem formalizados como scripts versionados — ver a issue
`#395` e suas sub-issues para o rastreio completo da decomposição (Postgres já
formalizado em `../bootstrap-standalone.sh` como referência de padrão; MinIO
e Kafka seguem o mesmo modelo em issues subsequentes).
