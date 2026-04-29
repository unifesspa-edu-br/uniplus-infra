# MinIO Distribuído

> Storage de objetos compatível com S3 API. Gerenciado via Docker Compose + systemd no host Linux.

## Visão geral

- **Modo:** Distribuído com Erasure Coding
- **Nós:** 4 ao todo (2 por DC)
- **Tolerância:** sobrevive à perda de 1 nó

## Buckets

| Bucket | Finalidade | Retenção | Política de acesso |
|--------|-----------|----------|-------------------|
| `quarentena/` | Recepção de uploads aguardando análise ClamAV | 24h auto-purge | Write via presigned URL |
| `aprovado/` | Documentos validados (limpos) | Vida útil do processo | Read via presigned URL |
| `bloqueado/` | Documentos infectados/inválidos | 90 dias | Sem acesso externo |

## Implementação pendente

- [ ] docker-compose.yml em modo distribuído
- [ ] Configuração de erasure coding entre os 4 nós
- [ ] Bucket policies (presigned URL apenas, TTL curto)
- [ ] Replicação assíncrona para MinIO master UNIFESSPA
- [ ] Lifecycle rules (auto-purge da quarentena)
- [ ] Configuração de eventos (notificações Kafka)
- [ ] Hardening SSL/TLS

## Validação

Veja [docs/VALIDATION-PLAN.md](../../docs/VALIDATION-PLAN.md) Cenário 7.
