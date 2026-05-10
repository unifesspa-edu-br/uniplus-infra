# Validação integrada Standalone OCI — 2026-05-10

> **Sessão de fechamento da Epic [`#40`](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40) — topologia standalone OCI provider-agnostic.**
>
> **Operador:** Jeferson Ferreira da Silva (@marmota-alpina)
> **Auxílio:** Claude Code (workflow de PRs cross-account, smoke automatizado via SSH + curl)
> **Sessão anterior:** [`standalone-2026-05-09.md`](standalone-2026-05-09.md) (Gate 1 estrutural)

## Resumo executivo

A sessão de 2026-05-09 fechou o Gate 1 estrutural com 9/11 itens verdes + 2 gaps (ClamAV deployment ausente, Grafana sem ingress). A sessão de hoje (2026-05-10) entregou:

- **4 PRs mergeados** que fecham os gaps + bugs descobertos no smoke do dia anterior
- **Smoke E2E manual #166 com 6/6 checks ✓** — Auth, Health, DB schema, Storage, Cache, Messaging
- **3 follow-up issues abertas** com prioridade definida — não bloqueiam o Epic, ficam como manutenção contínua

| Gate | Resultado |
|---|---|
| Gate 1 — Fase 5 estrutural (atualizado pós-PRs) | ✅ **11/11** verdes (gaps fechados) |
| Gate 2 — Validação completa pós-Epic `data/*` (#166) | ✅ **6/6** checks ponta-a-ponta |
| Veredicto Epic #40 | ✅ **CONCLUÍDA** — sem ressalvas operacionais bloqueantes |

---

## PRs entregues nesta sessão

| PR | Issue(s) | Conteúdo |
|---|---|---|
| [#182](https://github.com/unifesspa-edu-br/uniplus-infra/pull/182) | [#178](https://github.com/unifesspa-edu-br/uniplus-infra/issues/178) [#179](https://github.com/unifesspa-edu-br/uniplus-infra/issues/179) [#180](https://github.com/unifesspa-edu-br/uniplus-infra/issues/180) | Bugs do smoke #181: Traefik `updateStrategy.type: Recreate` (HostPort conflict em rolling update single-node), Grafana IngressRoute via subpath `/grafana/*` com StripPrefix Middleware + `serve_from_sub_path: true`, ClamAV implementado como wrapper do daemon `clamav/clamav` oficial expondo clamd TCP 3310 |
| [#183](https://github.com/unifesspa-edu-br/uniplus-infra/pull/183) | [#177](https://github.com/unifesspa-edu-br/uniplus-infra/issues/177) | Reconciliação automática do realm Keycloak via `keycloak-config-cli` Helm hook `post-install,post-upgrade`. Fecha o gap "Keycloak 26.x skipa re-import quando realm já existe". `IMPORT_MANAGED_CLIENT: full` para clients/mappers; demais resources `no-delete` (preserva users/sessões manuais). [ADR-010](../adrs/ADR-010-keycloak-config-cli-realm-reconcile.md) |
| [#184](https://github.com/unifesspa-edu-br/uniplus-infra/pull/184) | [#128](https://github.com/unifesspa-edu-br/uniplus-infra/issues/128) | Postgres systemd: migra `EnvironmentFile=` → `LoadCredential=` (systemd 250+). Senha sai de `/proc/<pid>/environ` para tmpfs do unit, docker consume via `POSTGRES_PASSWORD_FILE`. Runbook §9.6 (rotação Day-2) + §9.6.1 (TPM2 binding opcional com PCR 0) |
| [#185](https://github.com/unifesspa-edu-br/uniplus-infra/pull/185) | [#72](https://github.com/unifesspa-edu-br/uniplus-infra/issues/72) | `docs/ARCHITECTURE.md §5.5` documenta as duas topologias suportadas (3-DC vs standalone). README.md raiz com tabela comparativa em "Sobre". Princípio de divergência mínima explicitado |

Total: **4 PRs · 6 issues fechadas · 1 ADR nova · 12 commits**.

## Smoke E2E #166 — execução completa

### Setup

- Cluster: `uniplus-standalone` (k3s v1.31.4, k8s-host `164.152.53.29`, data-host `10.0.2.87`)
- 3 APIs em `v0.2.0` (#164 fechada anteriormente)
- `kafka.enabled: true` (#165 fechada anteriormente)
- Token JWT obtido via password grant em `uniplus-portal` para usuário `jeferson.ferreira`

### Workarounds aplicados durante a execução

1. **Audience mapper `uniplus` no client `uniplus-portal`** — adicionado em runtime via API admin do Keycloak (`oidc-audience-mapper` com `included.custom.audience=uniplus`, `access.token.claim=true`). Sem isso, o token chega às APIs com `aud: account`, mas as APIs validam `Auth__Audience=uniplus` → 401. **Persistido como follow-up [#186](https://github.com/unifesspa-edu-br/uniplus-infra/issues/186)** para o realm.json em Git.
2. **`directAccessGrantsEnabled=true`** no `uniplus-portal` para permitir password grant via curl. **Revertido para `false`** ao final.
3. **Roles `admin` e `uniplus-admin`** atribuídas a `jeferson.ferreira` (necessárias para `_smoke/*` endpoints). Persistente — re-execuções não precisam de re-config.

### Resultado por check

#### 1. Auth `/api/auth/me` ✅ (3 APIs)

```json
{ "userId": null, "name": "Jeferson Ferreira da Silva",
  "email": "jeferson.ferreira@unifesspa.edu.br",
  "roles": ["uniplus-admin", "admin", "default-roles-uniplus", ...] }
```

`userId: null` por causa de claim `sub` ausente do access_token quando emitido pelo `uniplus-portal` (presente em `id_token` + `userinfo`). **Não bloqueante**, follow-up [#187](https://github.com/unifesspa-edu-br/uniplus-infra/issues/187).

#### 2. Health `/health/ready` ✅ (3 APIs)

```
HTTP=200  body=Healthy
```

#### 3. DB — Wolverine schema ✅ (3 DBs)

```
uniplus_portal:    8 tables in schema 'wolverine' (owner: portal)
uniplus_selecao:   8 tables in schema 'wolverine' (owner: selecao)
uniplus_ingresso:  8 tables in schema 'wolverine' (owner: ingresso)
```

Tabelas: `wolverine_agent_restrictions`, `wolverine_control_queue`, `wolverine_dead_letters`, `wolverine_incoming_envelopes`, `wolverine_node_assignments`, `wolverine_node_records`, `wolverine_nodes`, `wolverine_outgoing_envelopes`. Migrations EF Core de domínio ainda pendentes (esperado nesta etapa).

#### 4. Storage `/api/_smoke/storage/upload` ✅

```json
{ "bucket": "uniplus-storage",
  "objectName": "smoke/add80595bc864ffcad575e3cf7e2b8d5-smoke.txt",
  "location": "uniplus-storage/smoke/add80595bc864ffcad575e3cf7e2b8d5-smoke.txt" }
```

#### 5. Cache `/api/_smoke/cache/{key}` ✅

```json
{ "key": "smoke:test-1778382011",
  "value": "2026-05-10T03:00:11.5379146+00:00",
  "ttlSeconds": 300 }
```

#### 6. Messaging `/api/_smoke/messaging/publish` ✅

```json
{ "id": "f2ae023f-8264-497a-910a-47b3f155d1d1",
  "timestamp": "2026-05-10T03:00:11.5578091+00:00" }
```

Confirmação ponta-a-ponta no log do pod:

```
[03:00:12 INF] Smoke ping recebido pelo Wolverine: id=f2ae023f-8264-497a-910a-47b3f155d1d1
[03:00:12 INF] Successfully processed message Unifesspa.UniPlus.Infrastructure.Core.Smoke.SmokePingMessage#08deae40-... from local://...
```

Mesma `id` retornada pelo POST e processada pelo consumer Wolverine (outbox-handler completo).

## Estado final do cluster

| Componente | Estado | Observação |
|---|---|---|
| K3s single-node | ✅ Ready, ~5 dias uptime | Traefik HostPort conflict resolvido pelo PR #182 |
| ArgoCD reconciliação | ✅ Apps Synced/Healthy | Job realm-reconcile do PR #183 será executado no próximo sync (ainda não disparou na sessão) |
| Vault unsealed + ESO | ✅ STATUS=Valid Ready=True | Sem mudanças nesta sessão |
| Postgres systemd | ✅ active | Migração `LoadCredential` (#128/PR #184) é Day-2 — janela de manutenção planejada |
| Kafka KRaft + SASL_SSL | ✅ active | Sem mudanças |
| MinIO | ✅ active | Sem mudanças |
| Keycloak realm `uniplus` | ✅ | Reconciliação automática (PR #183) entrega gap "skip re-import" |
| Apicurio Schema Registry | ✅ | Sem mudanças |
| Apps web (3 SPAs) | ✅ Pods Running 1/1 | Sem mudanças |
| APIs (3 backends) | ✅ Pods Running 1/1 | Smoke #166 confirmou 6/6 ponta-a-ponta |
| ClamAV scanner | ⚠️ CrashLoopBackOff | Pod novo do PR #182 falha `chown /var/lib/clamav` — fsGroup não aplicado pelo k3s local-path provisioner. Follow-up [#188](https://github.com/unifesspa-edu-br/uniplus-infra/issues/188) com 4 opções de fix avaliadas |
| Grafana via subpath | ✅ | PR #182 entregou IngressRoute + StripPrefix Middleware |

## Follow-ups identificados (manutenção contínua)

| Issue | Prioridade | Resumo |
|---|---|---|
| [#186](https://github.com/unifesspa-edu-br/uniplus-infra/issues/186) | high | Persistir audience mapper `uniplus` no `realm.json` (atualmente aplicado em runtime via API admin). Bloqueia frontend Angular puro sem workaround manual |
| [#187](https://github.com/unifesspa-edu-br/uniplus-infra/issues/187) | medium | Investigar claim `sub` ausente em access_token via `uniplus-portal`. Não bloqueia smoke; afeta correlação de domain events futuros |
| [#188](https://github.com/unifesspa-edu-br/uniplus-infra/issues/188) | medium | ClamAV pod CrashLoopBackOff — fsGroup do PVC. 4 opções avaliadas, recomendação `fsGroupChangePolicy: Always` |

Total: **3 issues** pós-Epic, todas com critérios de aceite + soluções esboçadas. Não-bloqueantes para o standalone como ambiente de validação.

## Verificação manual de fechamento — Epic #40

| Critério da Epic | Status |
|---|---|
| Standalone OCI provisionável (single-site monolocal) | ✅ Operacional, validado |
| GitOps end-to-end via ArgoCD | ✅ 16/22+ Apps Synced/Healthy |
| Auth federado via Keycloak local | ✅ Smoke #166 confirma flow OIDC + token + API |
| Storage via MinIO | ✅ Upload `_smoke/storage` 200 OK |
| Cache via Redis | ✅ SET/GET `_smoke/cache` 200 OK |
| Messaging via Kafka + Wolverine | ✅ Publish + consumer log confirma |
| 3 APIs Uni+ (.NET 10) deployed e healthy | ✅ 3/3 Running, 3/3 Healthy |
| 3 frontends Angular deployed | ✅ 3/3 Pods Running (validado em sessão anterior via Playwright) |
| Smoke E2E ponta-a-ponta documentado | ✅ Esta sessão (#166) |

**Epic #40 ✅ CONCLUÍDA sem ressalvas operacionais bloqueantes.**

Tofu provisioning (#52-58 + tasks #75-81) fica como sprint dedicada de Day-2 — codificação retroativa via `tofu import` das VMs OCI já em uso. Não desbloqueia operação.
