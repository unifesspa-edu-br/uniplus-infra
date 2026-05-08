# redis-ui

RedisInsight 2.x (Redis Inc., Apache 2.0) como UI de admin/inspect para o Redis 8.6.3 standalone (`10.0.2.87:6379`).

## Quando usar

Ative apenas em ambientes que precisam de UI Redis (debug operacional, ver keys/TTL/memory). Em standalone roda 1 réplica conectando ao Redis systemd no data-host via subnet privada VCN.

## Auth

RedisInsight 2.x **não tem auth nativa**. Proteção via Traefik `basicAuth` middleware (htpasswd bcrypt custodiado em Vault em `secret/standalone/redis-ui/basic-auth`). Operador gera uma vez:

```bash
htpasswd -nbB <username> <senha>
# saída: username:$2y$05$<bcrypt_hash>
```

Custodia em Vault e o ESO sintetiza Secret K8s no formato Traefik espera.

Para SSO via Keycloak no futuro, considerar Traefik `forwardAuth` middleware + oauth2-proxy.

## Connection pré-setup

Backend Redis pré-cadastrado via env vars `RI_REDIS_*`. Aparece automaticamente no UI no primeiro acesso. Em standalone:

| Env | Valor |
|---|---|
| `RI_REDIS_HOST` | `10.0.2.87` |
| `RI_REDIS_PORT` | `6379` |
| `RI_REDIS_USERNAME` | `default` |
| `RI_REDIS_PASSWORD` | (do Vault `secret/standalone/redis/default`) |

## Operação

Procedimentos detalhados em `docs/RUNBOOKS.md` §16.
