# PostgreSQL + Patroni + PgBouncer

> Componentes stateful **fora do Kubernetes**, gerenciados via Docker Compose + systemd no host Linux.

## Visão geral

A camada de banco do Uni+ é composta por:

- **3 instâncias PostgreSQL 16** — uma por API (Portal, Seleção, Ingresso)
- **Patroni** — gerenciamento de alta disponibilidade com failover automático
- **etcd** — backend distribuído do Patroni (3 nós: SP1 + SP2 + UNIFESSPA witness)
- **PgBouncer** — pool de conexões na frente de cada Postgres
- **pgBackRest** — backup contínuo para infra UNIFESSPA

## Distribuição de primaries por DC

| Banco | Primary | Replica |
|-------|---------|---------|
| `uniplus_portal` | SP1 | SP2 |
| `uniplus_selecao` | SP2 | SP1 |
| `uniplus_ingresso` | SP1 | SP2 |

Esta distribuição balanceia carga de escrita e exercita rotineiramente os mecanismos de failover em ambos os lados.

## Pré-requisitos

- Docker + Docker Compose instalado no host
- Volume LVM dedicado em `/var/lib/postgres` (ver [SETUP.md](../../docs/SETUP.md))
- Conectividade entre nós via L2L (ou LAN no laboratório)
- Witness etcd acessível em `192.168.0.21:2379` (lab) ou via IPSEC (prod)

## Estrutura

```
data/postgres/
├── README.md                        # este arquivo
├── docker-compose.yml               # services
├── patroni/
│   ├── patroni-portal-sp1.yml       # config Patroni para Portal em SP1
│   ├── patroni-portal-sp2.yml
│   ├── patroni-selecao-sp1.yml
│   ├── patroni-selecao-sp2.yml
│   ├── patroni-ingresso-sp1.yml
│   └── patroni-ingresso-sp2.yml
├── pgbouncer/
│   └── pgbouncer.ini
├── pgbackrest/
│   └── pgbackrest.conf
└── postgresql.conf.template          # config base PostgreSQL
```

## Configuração resumida do Patroni

Cada banco terá um `patroni.yml` específico, mas com a mesma estrutura geral:

```yaml
scope: uniplus_portal_cluster
namespace: /uniplus/
name: postgres-portal-sp1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.0.10:8008

etcd3:
  hosts:
    - 192.168.0.10:2379    # SP1
    - 192.168.0.20:2379    # SP2
    - 192.168.0.21:2379    # Witness UNIFESSPA

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576
    synchronous_mode: false
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 200
        shared_buffers: 2GB
        effective_cache_size: 6GB
        wal_level: replica
        hot_standby: 'on'
        max_wal_senders: 10
        max_replication_slots: 10
        wal_log_hints: 'on'
        archive_mode: 'on'
        archive_command: 'pgbackrest --stanza=uniplus_portal archive-push %p'

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.0.10:5432
  data_dir: /var/lib/postgres/portal/data
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    superuser:
      username: postgres
      password: !!ref-vault://secret/postgres/portal/superuser
    replication:
      username: replicator
      password: !!ref-vault://secret/postgres/portal/replicator
```

⚠️ **Senhas via Vault**: nunca commitar senhas reais. Usar secrets externos via `external-secrets` ou injeção via env vars no Docker Compose.

## Backup com pgBackRest

```ini
# pgbackrest.conf
[global]
repo1-path=/var/lib/pgbackrest
repo1-retention-full=2
repo1-retention-diff=4

[uniplus_portal]
pg1-host=postgres-portal-sp1
pg1-path=/var/lib/postgres/portal/data
```

Cron:
```cron
# Full semanal aos domingos
0 2 * * 0 pgbackrest --stanza=uniplus_portal --type=full backup

# Diferencial diário
0 3 * * 1-6 pgbackrest --stanza=uniplus_portal --type=diff backup
```

## Implementação pendente

- [ ] docker-compose.yml com todas as instâncias
- [ ] patroni-*.yml para cada DC e cada banco
- [ ] pgbouncer.ini para todos os bancos
- [ ] pgbackrest.conf
- [ ] systemd unit files para gestão do ciclo de vida
- [ ] scripts de bootstrap inicial
- [ ] runbooks específicos de operação

## Operação

Veja [docs/RUNBOOKS.md](../../docs/RUNBOOKS.md) para procedimentos operacionais (failover, backup, restore).

## Validação

Veja [docs/VALIDATION-PLAN.md](../../docs/VALIDATION-PLAN.md) Cenários 3 (failover Postgres), 4 (split-brain), 5 (catch-up) e 12 (backup/restore).
