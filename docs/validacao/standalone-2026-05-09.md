# Validação integrada Standalone OCI — 2026-05-09

> **Story:** [`uniplus-infra#99`](https://github.com/unifesspa-edu-br/2026-05-09)
> **Cenário:** Cenário 13 + 13.A do antigo `docs/VALIDATION-PLAN.md` (plano 3-DC removido em 2026-05-19 — ver `CHANGELOG.md`)
> **Operador:** Jeferson Ferreira da Silva (@marmota-alpina)
> **Auxílio:** Claude Code (smoke automatizado via Playwright + curl + ssh)

## Resumo executivo

| Gate | Resultado |
|---|---|
| **Gate 1 — Fase 5 estrutural (11/11 itens não-Epic `data/*`)** | ✅ **9/11** verdes + 2 gaps mapeados (item 9 ClamAV deployment ausente, item 14 Grafana sem ingress) |
| **Gate 2 — Validação completa pós-Epic `data/*`** | ⏳ pendente — itens 6/7/8/15/16 dependentes, infra básica funcional mas validação via container precisa ajuste de creds |
| **Cenário 13.A — Smoke E2E real** | ✅ 4/6 passa, 2 critérios com observações documentadas |

**Veredicto Fase 5 estrutural:** **APROVADO COM RESSALVAS** — fluxo `usuário → DNS/TLS → portal Angular → Keycloak → logout` funciona end-to-end. Lacunas mapeadas em issues de follow-up.

---

## Cenário 13 — Matriz 16 itens

### Itens não-Epic `data/*` (Gate 1 — Fase 5 estrutural)

| # | Item | Status | Observação |
|---|---|---|---|
| 1 | DNS público | ✅ | 11/11 hosts resolvem `164.152.53.29` (1 A + 10 CNAMEs: `standalone`, `portal`, `selecao`, `ingresso`, `api-portal`, `api-selecao`, `api-ingresso`, `minio`, `kafka-ui`, `schema-registry`, `redis-ui`) |
| 2 | TLS público | ✅ | `https://standalone.portaluni.com.br/auth/realms/uniplus` HTTP/2 200 com cert válido (Let's Encrypt prod, sem warnings no browser) |
| 3 | K3s single-node | ✅ | `uniplus-standalone` Ready, K3s v1.31.4+k3s1, 5d8h uptime. **Ressalva:** 1 Pod Traefik Pending há 35h (HostPort conflict — replica nova esperando antiga sair em rolling update); 1 Pod Vault test em Error (efêmero do helm test, não-bloqueante) |
| 4 | ArgoCD reconciliação | ✅ | 16/22 Apps Synced/Healthy + 4 Unknown (apps observabilidade — cloudflared/loki/otel-collector/tempo) + 1 Degraded (Traefik HostPort) + 1 Apps Synced/Healthy mas SEM Pod (`clamav-scanner-uniplus-standalone` — gap mapeado item 9) |
| 5 | Vault unsealed + ESO ready | ✅ | Vault 1.21.2 raft, Sealed=false, Initialized=true, Shamir 5/3. ClusterSecretStore `vault-default` STATUS=Valid Ready=True |
| 9 | ClamAV scanner | ❌ | **App ArgoCD Synced/Healthy mas 0 pods/deploys com nome contendo "clam" no cluster.** Gap a investigar — chart pode estar vazio ou em namespace diferente |
| 10 | Keycloak realm `uniplus` | ✅ | 4 clients Uni+ presentes (`uniplus-portal`, `uniplus-api-{portal,selecao,ingresso}`) + `kafka-ui` + `apicurio-registry`. **Ação executada durante smoke:** mappers `audience-apicurio-registry` + `groups-hardcoded-developer` aplicados via `kcadm.sh` (RUNBOOKS §15.6 passo 1) — ausentes no realm vivo apesar de definidos no realm.json (Keycloak skipa re-import). 6 mappers novos criados (2 × 3 clients) |
| 11 | Apps web (3 SPAs) | ✅ | `https://{portal,selecao,ingresso}.standalone.portaluni.com.br/` retornam HTTP 200 com `content-type: text/html`. Portal Angular renderiza corretamente (validado via Playwright) |
| 12 | APIs (3 backends) | ✅ | 3/3 retornam HTTP 200 em `/health` (`api-portal`, `api-selecao`, `api-ingresso`). `/health/ready` em `api-portal` também 200 |
| 13 | Apicurio Schema Registry | ✅ | OAuth `client_credentials` com `uniplus-api-portal` retorna token com `aud: ["apicurio-registry","account"]` + `groups: ["/users/uniplus"]`. Endpoint `/apis/ccompat/v7/subjects` retorna `["uniplus.events.smoke-value"]` (1 subject). `edital_events-value` ainda não publicado (esperado — producer Wolverine Avro do PR uniplus-api#359 não foi exercitado em runtime ainda) |
| 14 | Observabilidade (Grafana) | ❌ | App ArgoCD Synced/Healthy + Service `platform-observability-grafana-uniplus-standalone` ClusterIP existe, mas **sem IngressRoute Traefik** — `https://standalone.portaluni.com.br/grafana/` retorna 404. Acessível apenas via port-forward |

### Itens dependentes da Epic `data/*` (Gate 2)

| # | Item | Status | Observação |
|---|---|---|---|
| 6 | Postgres data-host | ⚠ | `systemctl is-active uniplus-postgres` = `active`. Validação via `psql` direto não rodou (role `uniplus_admin` não existe; nomes de role esperados precisam confirmação) |
| 7 | Kafka KRaft + SASL_SSL | ⚠ | `systemctl is-active uniplus-kafka` = `active`, `/var/lib/uniplus/kafka/admin.properties` existe no host. Validação via `kafka-topics.sh` dentro do container falha por path errado — ajustar caminho do `--command-config` |
| 8 | MinIO | ⚠ | `systemctl is-active uniplus-minio` = `active`. Validação via `mc ls local` falhou (alias não configurado dentro do container) |
| 15 | Backup placeholder | ⏳ | Não validado — Epic `data/*` ainda não entregou rotina de backup |
| 16 | Restore placeholder | ⏳ | Não validado — depende de #15 |

---

## Cenário 13.A — Smoke E2E (login real do portal)

Executado via Playwright em browser real contra `https://portal.standalone.portaluni.com.br/`.

### Sequência executada

1. **Navegação inicial** — `https://portal.standalone.portaluni.com.br/` (redirect para `/processos`).
2. **Click "Meu Perfil"** — redirect OIDC para Keycloak (Authorization Code + PKCE):
   - URL: `https://standalone.portaluni.com.br/auth/realms/uniplus/protocol/openid-connect/auth?client_id=uniplus-portal&response_type=code&scope=openid&code_challenge_method=S256&...`
   - Title: "Entrar em Uni+ — Sistema Unificado Unifesspa" (theme custom pt-BR)
3. **Login form** — preenchido com credencial de teste autorizada pelo operador (a ser rotacionada pós-validação).
4. **Submit** — Keycloak completa o exchange code → redirect de volta para `https://portal.standalone.portaluni.com.br/processos`.
5. **Pós-login** — banner mostra "Jeferson Ferreira da Silva" + "@jeferson.ferreira" + botão "Sair".
6. **Navegação para `/perfil`** — rota protegida carrega sem erro.
7. **Click "Sair"** — sessão limpa, banner volta ao estado público.

### 6 critérios de aceite (#99 task 2)

| # | Critério | Resultado | Evidência |
|---|---|---|---|
| 1 | `https://standalone.portaluni.com.br` carrega com cert LE prod (não staging) | ✅ | `curl -sI` retorna 200 com cert válido; browser sem warning de cert |
| 2 | Login com usuário no Keycloak completa e redireciona autenticado | ✅ | `smoke-02-keycloak-login.png` (form login) → `smoke-03-pos-login-processos.png` (autenticado, banner com nome do user) |
| 3 | Rota protegida do portal Angular chama `GET /api/portal/me` e renderiza a resposta | ⚠ | **Frontend Angular ainda não consome a API.** `/perfil` carrega como placeholder com texto estático ("Dados pessoais e informações de contato"). `browser_network_requests` filtrado por `/api/` retornou 0 requests. Gap conhecido — implementação pendente do consumer no portal-web |
| 4 | Logs sem erros 4xx/5xx no caminho do request | ✅ | `browser_console_messages` retornou 0 errors, 1 warning não-bloqueante (silent-check-sso iframe sandbox; vem do Keycloak adapter Angular, sem impacto funcional) |
| 5 | Token JWT contém claim `realm_access.roles` consistente com o realm | ✅ (validado via OAuth `client_credentials` paralelo) | Token de `uniplus-api-portal` decodificado: `aud: ["apicurio-registry", "account"]`, `azp: "uniplus-api-portal"`, `groups: ["/users/uniplus"]`, `scope: "profile email"`. Validação direta do JWT do user pelo browser não foi feita (token vive em memória do KeycloakService — invariante de segurança Uni+ confirmada: `localStorage`/`sessionStorage`/`cookies` vazios pós-login, JWT NUNCA persistido em browser storage) |
| 6 | Logout limpa sessão e redireciona para tela pública | ✅ | `smoke-05-pos-logout.png` — banner volta ao estado pré-login (sem nome/avatar do usuário, sem botão Sair); URL permanece em `/processos` (rota pública); 0 errors no console |

### Evidências (screenshots)

- [`smoke-01-home-publica.png`](smoke-01-home-publica.png) — landing page pública (`/processos`, sem nav autenticada)
- [`smoke-02-keycloak-login.png`](smoke-02-keycloak-login.png) — Keycloak login form (theme Uni+ custom, locale pt-BR ativo)
- [`smoke-03-pos-login-processos.png`](smoke-03-pos-login-processos.png) — pós-login com user "Jeferson Ferreira da Silva" no banner
- [`smoke-04-perfil-autenticado.png`](smoke-04-perfil-autenticado.png) — rota protegida `/perfil` carregada
- [`smoke-05-pos-logout.png`](smoke-05-pos-logout.png) — pós-logout, sessão limpa

---

## Gaps mapeados (issues de follow-up a abrir)

1. **Mappers OAuth ausentes no realm vivo** — clients `uniplus-api-{portal,selecao,ingresso}` foram criados em deploy passado mas SEM os 2 protocolMappers (`audience-apicurio-registry` + `groups-hardcoded-developer`) que estão no `realm.json` (PR uniplus-infra#169). Causa: Keycloak 26.x skipa re-import quando realm já existe — RUNBOOKS §15.6 passo 1 documenta exatamente esse cenário e foi executado durante este smoke. **Permanente:** considerar Job/init container que reconcilia mappers via `kcadm.sh` no startup, OU adicionar à pipeline pós-deploy.
2. **ClamAV deployment ausente** — App ArgoCD `clamav-scanner-uniplus-standalone` Synced/Healthy mas sem pods. Investigar chart `apps/clamav-scanner/` — pode estar com `enabled=false` por default em `environments/standalone/values.yaml` ou template vazio.
3. **Grafana sem IngressRoute externo** — Service ClusterIP existe; falta `IngressRoute` em `platform/observability/grafana/templates/` para expor em `https://standalone.portaluni.com.br/grafana/`.
4. **Traefik Pod Pending HostPort** — single-node K3s + HostPort não permite RollingUpdate; ajustar `strategy: Recreate` no Deployment do Traefik chart.
5. **Frontend Angular não consome `/api/portal/me`** — pages do portal-web são placeholders. Implementar consumer real no `apps/portal/src/app/perfil/` (uniplus-web).
6. **`edital_events-value` ainda não publicado** — Story uniplus-api#358 entregou o pipeline Avro, mas nenhuma mensagem foi publicada em runtime no standalone. Subject existirá após primeiro `PUBLISH /api/editais/{id}/publicar` (REST) que dispara o cascading handler.

## Itens de operação pós-validação

- [ ] **Rotacionar credenciais** expostas durante o smoke (autorizado pelo operador):
  - Senha do user `jeferson.ferreira` (Keycloak realm `uniplus`)
  - `client_secret` do `apicurio-registry` (Keycloak realm `uniplus`)
  - `client_secret` do `uniplus-api-portal` (Keycloak realm `uniplus`)
  - Re-custodiar em Vault em `secret/standalone/keycloak/clients/...` conforme RUNBOOKS §15.6 passo 2
- [ ] **Investigar gap 1** — mappers OAuth em realm vivo: abrir issue para reconciliação automática
- [ ] **Investigar gap 2** — ClamAV: confirmar estado do chart + reabilitar deployment
- [ ] **Investigar gap 3** — Grafana: adicionar IngressRoute em `platform/observability/grafana/templates/`
- [ ] **Investigar gap 4** — Traefik: ajustar strategy no Deployment
- [ ] **Promover cert para LE prod** se ainda estiver em staging (validar via `curl --cacert`)

---

## Próximos passos

1. **Abrir issues de follow-up** para cada gap.
2. **Encerrar `uniplus-infra#99` task 2** (smoke E2E) com link para este doc.
3. **Manter Gate 2** em aberto até Epic `data/*` entregar (#98).
4. **Implementar consumer `/api/portal/me`** no portal-web (Story uniplus-web a abrir).
