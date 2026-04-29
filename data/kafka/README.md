# Apache Kafka (KRaft mode)

> Bus de eventos de domínio do Uni+. Gerenciado via Docker Compose + systemd no host Linux.

## Visão geral

- **Modo:** KRaft (sem ZooKeeper) — Apache Kafka 3.7+
- **Brokers:** 3 ao todo, distribuídos entre os DCs
  - SP1: 1-2 brokers
  - SP2: 1-2 brokers
- **Replication factor padrão:** 2
- **Min ISR padrão:** 1 (garante disponibilidade)

## Tópicos principais

| Tópico | Producer | Consumer | Partições | Retenção |
|--------|----------|----------|-----------|----------|
| `documento.upload.solicitado` | API Seleção, API Ingresso | ClamAV Scanner | 6 | 7 dias |
| `documento.aprovado` | ClamAV Scanner | API Seleção, API Ingresso | 6 | 7 dias |
| `documento.rejeitado` | ClamAV Scanner | API Seleção, API Ingresso | 6 | 30 dias |
| `inscricao.criada` | API Seleção | API Portal (notificação) | 6 | 30 dias |
| `inscricao.classificada` | API Seleção | API Ingresso | 6 | 30 dias |
| `matricula.efetivada` | API Ingresso | API Portal | 6 | 90 dias |

## Implementação pendente

- [ ] docker-compose.yml com 3 brokers KRaft
- [ ] server.properties para cada broker
- [ ] Schema Registry (Apache Avro/Protobuf)
- [ ] MirrorMaker 2 para replicação inter-DC
- [ ] Backup de configurações

## Estratégia de replicação

A replicação acontece **dentro do cluster Kafka** (replication.factor=2). Em caso de queda de um DC, o cluster continua funcionando com os brokers restantes desde que ISR seja ≥ 1.

Para DR off-site (cópia para UNIFESSPA), considera-se MirrorMaker 2 em fase posterior.

## Validação

Veja [docs/VALIDATION-PLAN.md](../../docs/VALIDATION-PLAN.md) Cenário 6.
