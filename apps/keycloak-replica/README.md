# keycloak-replica

Serviço OIDC local do Uni+ baseado em **Keycloak 26.6.x**.

> O nome do chart é legado (mantido para compatibilidade com o ApplicationSet existente). Na arquitetura, este componente é o serviço OIDC local de cada DC.

## Visão geral

Componente da plataforma Uni+ responsável por login OIDC local em cada DC. Persiste em Postgres externo (data-host em standalone; Patroni em SP1/SP2 quando aplicável), expõe-se via Traefik IngressRoute em path `/auth/*` e provisiona o realm `uniplus` declarativamente via `--import-realm`.

Ver [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) para o contexto arquitetural e [docs/RUNBOOKS.md §10](../../docs/RUNBOOKS.md) para procedimentos operacionais.

## Pré-requisitos

- Kubernetes 1.30+ + Helm 3.x
- Postgres com database `keycloak` + role `keycloak` provisionados (em standalone, codificado em `scripts/bootstrap-standalone.sh::step_data_setup_postgres`)
- Vault de aplicação inicializado, ESO `ClusterSecretStore` `vault-default` com STATUS=Valid+Ready
- Secrets no Vault:
  - `secret/standalone/postgres/keycloak` (fields: `host`, `port`, `database`, `username`, `password`)
  - `secret/standalone/keycloak/admin` (fields: `username`, `password`) — bootstrap admin
  - `secret/standalone/keycloak/clients/uniplus-portal` (field: `client_secret`)
- cert-manager + ClusterIssuer `letsencrypt-staging` ou `letsencrypt-prod` Ready
- Traefik Running com hostPort 80/443 (single-host) ou Service LoadBalancer (multi-DC)

## Como o chart é aplicado

`apps/keycloak-replica/` é referenciado pelo ApplicationSet `uniplus-apps` em `argocd/applicationset.yaml`. Cada cluster registrado (label `uniplus.io/managed=true`) recebe uma `Application` chamada `keycloak-replica-<release>` que aterrissa no namespace `uniplus`.

Por padrão o chart fica **desabilitado** (`keycloak.enabled: false`). Apenas environments que explicitamente ligam (ex.: `environments/standalone/values.yaml`) sobem os recursos.

## Templates entregues

- `templates/deployment.yaml` — Deployment Keycloak 26.6.x com `start --import-realm`, env vars de DB/admin via secret refs, probes na management port 9000
- `templates/service.yaml` — ClusterIP com port `http` (8080) + port `management` (9000)
- `templates/externalsecret.yaml` — 3 ExternalSecrets (DB, bootstrap admin, client secret) consumindo `ClusterSecretStore vault-default`
- `templates/configmap-realm.yaml` — ConfigMap com `uniplus-realm.json` montado em `/opt/keycloak/data/import/`
- `templates/ingressroute.yaml` — Traefik IngressRoute path `/auth/*` com TLS via cert-manager
- `templates/networkpolicy.yaml` — egress: data-host:5432, vault, DNS; ingress: Traefik (8080), Prometheus (9000)
- `templates/servicemonitor.yaml` — scrape do `/metrics` na management port (gateado por `serviceMonitor.enabled`)

## Variáveis Keycloak relevantes

O chart codifica estas opções de configuração runtime do Keycloak 26.x:

| Env var | Origem | Notas |
|---|---|---|
| `KC_DB=postgres` | values | Único vendor suportado pelo chart |
| `KC_DB_URL_HOST/PORT/DATABASE` | values (`keycloak.database.*`) | Endpoint do Postgres externo |
| `KC_DB_USERNAME` / `KC_DB_PASSWORD` | ExternalSecret (Vault) | `secret/.../postgres/keycloak` |
| `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` | ExternalSecret (Vault) | Substitui `KEYCLOAK_ADMIN` (deprecado em 26.x) |
| `KC_HOSTNAME` | values (`keycloak.hostname.url`) | URL completa com path (`https://example.org/auth`) — recomendado em 26.x atrás de proxy com path |
| `KC_HOSTNAME_STRICT=true` | values | Default em prod profile |
| `KC_HTTP_ENABLED=true` | values | TLS termina no Traefik |
| `KC_HTTP_RELATIVE_PATH=/auth` | values | Path-routing servido por Keycloak |
| `KC_PROXY_HEADERS=xforwarded` | values | Substitui `KC_PROXY=edge` (deprecado em 26.x) |
| `KC_HEALTH_ENABLED=true` | values | `/health/{live,ready,started}` na port 9000 |
| `KC_METRICS_ENABLED=true` | values | `/metrics` na port 9000 |
| `UNIPLUS_PORTAL_CLIENT_SECRET` | ExternalSecret (Vault) | Substituído em `uniplus-realm.json` via `${VAR}` |

## Decisões de design

- **Imagem stock + `start --import-realm`** (sem rebuild custom): a imagem `quay.io/keycloak/keycloak:26.6.1` traz health/metrics built-in. `start` (sem `--optimized`) deixa o Keycloak fazer auto-build na primeira inicialização — `startupProbe.failureThreshold: 60` (×10s = 10min) absorve a janela.
- **Realm import idempotente**: `--import-realm` em 26.x **não re-importa** se o realm já existir, preservando mudanças via Admin UI. Para forçar reimport: `kc.sh import` explícito (não automático).
- **Client secret via env substitution**: `uniplus-realm.json` declara `"secret": "${UNIPLUS_PORTAL_CLIENT_SECRET}"` — Keycloak substitui no parse com o env var setado pela ExternalSecret. Sem hardcode no Git.
- **Sem PV**: estado durável vive todo no Postgres. `/tmp` em emptyDir.
- **`hostNetwork: false` por default**: workaround de #123 não é mais necessário após PR #125. Manter o flag para fallback se houver regressão.

## Limitações conhecidas

- **Single-replica only neste chart**: standalone single-node = 1 réplica (correto). Para multi-DC ativo-ativo (lab/prod-{sp1,sp2}) o approach será diferente — issue separada.
- **Federação Gov.br não implementada**: `keycloak.govbr.enabled: false` é flag inerte hoje. ADR-018 cobre o roadmap; depende deste chart estar de pé.
- **Sem rotação automática do client secret**: rotacionar requer `kcadm.sh set-client-secret` + atualizar Vault — procedimento em `docs/RUNBOOKS.md §10`.

## Validação

```bash
# Lint local
helm lint apps/keycloak-replica/

# Render contra standalone (envs reais)
helm template keycloak-replica apps/keycloak-replica/ \
  -f environments/standalone/values.yaml | kubectl apply --dry-run=client -f -

# Schema
make schema-validate
```

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra). Mudanças que tocam `environments/prod-*` exigem 2 aprovações conforme [CONTRIBUTING.md](../../CONTRIBUTING.md).
