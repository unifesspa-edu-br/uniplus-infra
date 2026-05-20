# Apache Kafka (KRaft mode)

> Bus de eventos de domínio do Uni+. Gerenciado via Docker Compose + systemd no host Linux.

## Visão geral

- **Modo:** KRaft (sem ZooKeeper) — Apache Kafka 3.7+
- **Brokers/controllers:** distribuídos entre `SP1`, `SP2` e `PA1` quando a latência permitir
- **Replication factor padrão alvo:** 3 para tópicos críticos
- **Min ISR padrão alvo:** 2 para tópicos críticos, ajustado conforme latência validada

Kafka deve usar quorum e replicação nativos do KRaft. Não criar mecanismo paralelo de replicação por fora do produto para simular ativo-ativo.

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

- [ ] docker-compose.yml com brokers/controllers KRaft distribuídos entre `SP1`, `SP2` e `PA1`
- [ ] server.properties para cada broker
- [ ] Schema Registry (Apache Avro/Protobuf)
- [ ] avaliação documentada: cluster KRaft único 3-DC vs clusters por DC + MirrorMaker 2, conforme latência real
- [ ] Backup de configurações

## Estratégia de replicação

A estratégia preferencial para a PoC é replicação **dentro do cluster Kafka**, com controllers/brokers distribuídos para tolerar a perda de qualquer 1 DC. A configuração final depende da latência real entre `SP1`, `SP2` e `PA1`.

Se a latência de `PA1` inviabilizar quorum KRaft saudável, a alternativa aceitável deve ser explicitamente documentada como clusters por DC com replicação via MirrorMaker 2. Essa decisão não deve ser feita por gambiarra de aplicação.

## Validação

Validação atual (standalone-compact): smoke pós-bootstrap em `scripts/validate-standalone.sh` + relatórios em `docs/validacao/`. O Cenário 6 (3-DC, replicação entre brokers cross-DC) era do plano 3-DC removido em 2026-05-19 e ainda não foi executado.
