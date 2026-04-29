# Redis

> Cache distribuído e sessões transientes. Gerenciado **dentro** do Kubernetes (não no host).

## Visão geral

Diferente de Postgres, Kafka e MinIO, o Redis roda **dentro do Kubernetes** porque:

- Estado é descartável (cache reconstruível das fontes autoritativas)
- Não há replicação cross-DC (cada cluster tem seu Redis local)
- Bitnami Helm chart é maduro e bem mantido
- Restart automático pelo K8s é suficiente

## Configuração

- **Mode:** master-replica com Sentinel para HA
- **Réplicas:** 1 master + 1 replica + Sentinel
- **Persistência:** AOF + snapshots periódicos (volume PVC)
- **Eviction policy:** `allkeys-lru` (cache, não storage)

## Uso pelas APIs

| Caso | TTL | Observações |
|------|-----|-------------|
| Cache de leitura (editais públicos) | 5 min | Read-through pattern |
| Cache de classificação | 1 min | Invalidação em mudança |
| Sessões temporárias (estado de upload) | 10 min | Não usar para sessão de auth |
| Distributed locks | 30s | Para operações concorrentes |

⚠️ **Sessões de autenticação** ficam no Keycloak (refresh tokens), não no Redis.

## Implementação pendente

- [ ] Helm chart referenciando Bitnami
- [ ] values.yaml com configuração HA
- [ ] PVC com volume adequado
- [ ] NetworkPolicy restritiva (apenas APIs do Uni+ acessam)
- [ ] ServiceMonitor para Prometheus
- [ ] Documentação de boas práticas para devs (TTL, key naming)

## Validação

Não há cenário específico no [VALIDATION-PLAN.md](../../docs/VALIDATION-PLAN.md). Validação implícita nos cenários de carga (Cenário 8).
