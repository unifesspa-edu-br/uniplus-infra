# MinIO Distribuído

> Storage de objetos compatível com S3 API. Gerenciado via Docker Compose + systemd no host Linux.

## Visão geral

- **Modo:** replicação/site ou bucket replication nativa do MinIO, conforme desenho validado
- **DCs:** `SP1`, `SP2` e `PA1`
- **Tolerância alvo:** perda de qualquer 1 DC sem perda de objetos já confirmados conforme política de replicação

Objetos devem usar chaves imutáveis/UUID sempre que possível. Isso reduz conflitos em replicação active-active e evita depender de sobrescrita concorrente.

## Buckets

| Bucket | Finalidade | Retenção | Política de acesso |
|--------|-----------|----------|-------------------|
| `quarentena/` | Recepção de uploads aguardando análise ClamAV | 24h auto-purge | Write via presigned URL |
| `aprovado/` | Documentos validados (limpos) | Vida útil do processo | Read via presigned URL |
| `bloqueado/` | Documentos infectados/inválidos | 90 dias | Sem acesso externo |

## Implementação pendente

- [ ] docker-compose.yml para `SP1`, `SP2` e `PA1`
- [ ] Configuração de replicação nativa entre sites/buckets
- [ ] Bucket policies (presigned URL apenas, TTL curto)
- [ ] Replicação assíncrona para `pa1-object-storage`
- [ ] Lifecycle rules (auto-purge da quarentena)
- [ ] Configuração de eventos (notificações Kafka)
- [ ] Hardening SSL/TLS

## Validação

Veja [docs/VALIDATION-PLAN.md](../../docs/VALIDATION-PLAN.md) Cenário 7.
