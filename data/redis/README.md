# Redis / Valkey

> Cache local por DC e sessões transientes. Gerenciado **dentro** do Kubernetes (não no host).

## Visão geral

Diferente de Postgres, Kafka e MinIO, Redis/Valkey roda **dentro do Kubernetes** porque:

- Estado é descartável (cache reconstruível das fontes autoritativas)
- Não há replicação cross-DC no desenho alvo (cada cluster tem cache local)
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

⚠️ **Sessões de autenticação** ficam no serviço OIDC (implementação atual Keycloak), não no Redis/Valkey.

⚠️ **Consenso global** não deve usar cache. Se um fluxo exigir coordenação forte entre DCs, ele deve usar banco, mensageria ou outro mecanismo com semântica explícita de consistência.

## Implementação pendente

- [ ] Escolha documentada entre Redis e Valkey conforme política de licenças open source/free
- [ ] Helm chart referenciando distribuição aprovada
- [ ] values.yaml com configuração HA
- [ ] PVC com volume adequado
- [ ] NetworkPolicy restritiva (apenas APIs do Uni+ acessam)
- [ ] ServiceMonitor para Prometheus
- [ ] Documentação de boas práticas para devs (TTL, key naming)

## Validação

Validação atual (standalone-compact): smoke pós-bootstrap em `scripts/validate-standalone.sh` (ping/auth). Cenários de carga ainda não executados.
