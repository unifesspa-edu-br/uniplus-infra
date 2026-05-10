# ADR-010: Reconciliação automática do realm Keycloak via keycloak-config-cli

- **Status:** 🟢 Aceita
- **Data:** 2026-05-10
- **Relacionado:** [Issue #177](https://github.com/unifesspa-edu-br/uniplus-infra/issues/177) · [Issue #163 (clients M2M)](https://github.com/unifesspa-edu-br/uniplus-infra/issues/163) · [PR #181 (smoke E2E)](https://github.com/unifesspa-edu-br/uniplus-infra/pull/181) · [Epic #40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40) · [ADR-008](ADR-008-topologia-standalone.md)

## Contexto

O chart `apps/keycloak-replica/` consome o realm `uniplus` declarativamente via `apps/keycloak-replica/files/uniplus-realm.json`, montado como ConfigMap e passado ao Keycloak através da flag `--import-realm`. Esse fluxo cobre o **primeiro deploy** corretamente: realm vazio → realm completo.

Limitação descoberta no smoke E2E (PR [#181](https://github.com/unifesspa-edu-br/uniplus-infra/pull/181)):

> **Keycloak 26.x skipa re-import do realm quando o realm já existe na DB.** Ou seja, mudanças posteriores no `uniplus-realm.json` (novos clients, novos protocolMappers, novos roles, alterações de scopes) **não** se propagam ao cluster vivo sem intervenção manual.

A descoberta veio com gap real: os 3 clients M2M `uniplus-api-{portal,selecao,ingresso}` adicionados em [PR #169](https://github.com/unifesspa-edu-br/uniplus-infra/pull/169) (Story #163) existiam no realm vivo mas SEM os 2 protocolMappers (`audience-apicurio-registry` + `groups-hardcoded-developer`) que projetam `aud: ["apicurio-registry"]` + `groups: ["/users/uniplus"]` no JWT. Resultado: tokens emitidos pelos clients M2M não autenticavam contra o Apicurio (401).

A mitigação do smoke foi executar `kcadm.sh` manualmente em cluster vivo (RUNBOOKS §15.6 passo 1) para criar os 6 mappers ausentes (2 mappers × 3 clients). Mas:

1. **Procedimento manual é frágil** — fácil esquecer em deploys subsequentes.
2. **Não cobre roles, groups, scopes, authentication flows** — qualquer mudança nesses tipos volta a sofrer drift silencioso.
3. **Evento "deploy do realm.json"** acaba sem garantia de que o cluster reflete o conteúdo do Git.

## Drivers da decisão

- **Single source of truth:** `realm.json` em Git deve ser o estado autoritativo. Drift entre Git e cluster precisa ser eliminado.
- **GitOps end-to-end:** ArgoCD reconcilia chart Helm; chart deve garantir que o realm também é reconciliado, não apenas instalado uma vez.
- **Sem operação manual recorrente:** RUNBOOKS §15.6 passo 1 é fallback de emergência, não procedimento de deploy.
- **Idempotência:** reconcilação re-aplicada N vezes deve ser no-op quando estado já bate.
- **Preservar customizações fora-do-realm.json:** users criados manualmente, sessões ativas, password rotations não devem ser destruídos por reconcile.
- **Compatibilidade Keycloak 26.x:** ferramenta deve suportar a versão atual sem migrations destrutivas.

## Alternativas consideradas

### Opção A — Init container do Pod do Keycloak

Init container que executa `kcadm.sh` durante startup, lendo o realm.json e criando/atualizando recursos via API.

- **Bom:** vive no mesmo Pod; sem dependência externa; sem state extra.
- **Ruim:** roda em **todo restart** do Pod (inclusive scale events, manutenção de nó), gerando custo desnecessário; complexidade de coordenar disponibilidade do Keycloak antes do init terminar (Pod fica `Init:0/1` esperando o próprio Pod ficar pronto — circular).

### Opção B — Helm hook Job rodando `kcadm.sh` diretamente

Job pós-install/upgrade que carrega o realm.json e cria recursos via `kcadm.sh`.

- **Bom:** simples, idempotente quando bem escrito.
- **Ruim:** `kcadm.sh` é shell-baseado e **não tem reconcile diff-based nativo** — escrever script idempotente para clients + mappers + roles + scopes + authentication flows é ~500 LOC frágeis. Foi o que executamos manualmente no smoke; automatizar isso significa reescrever a ferramenta certa.

### Opção C — `keycloak-config-cli` via Helm hook Job (escolhida)

Job pós-install/upgrade rodando `quay.io/adorsys/keycloak-config-cli`, ferramenta JVM dedicada que:

- Aceita o `realm.json` como entrada (mesmo arquivo já consumido pelo `--import-realm` inicial).
- Compara state do realm vivo com declaração e aplica diff via API REST do Keycloak.
- Suporta `IMPORT_MANAGED_*` env vars que controlam por tipo de recurso o que pode ser CRIADO/ATUALIZADO/DELETADO (`full`, `no-delete`, `read-only`, `none`).
- Mantida ativamente por adorsys, releases alinhadas com majors do Keycloak.

- **Bom:** ferramenta correta para o problema; reconcile diff-based; preserva resources fora do JSON via `no-delete`; mantida; community-driven; suporta substituição de variáveis (`${VAR}`) no JSON, mantendo compatibilidade com o pattern do `--import-realm`.
- **Ruim:** mais uma imagem para validar/atualizar; tag tem que casar com versão major do Keycloak (26.x → 26.x).

### Opção D — Implementar keycloak-config-cli próprio em Go

Reescrever a lib em Go, distribuído como container minimal.

- **Bom:** propriedade total, footprint menor, integração direta com observability stack.
- **Ruim:** custo de manutenção alto; reinventar a roda; não justificável para o tamanho do problema.

## Decisão

**Adotar opção C** — `keycloak-config-cli` (adorsys) como Job Helm hook `post-install,post-upgrade` no chart `apps/keycloak-replica/`.

### Configuração canônica

- **Tag da imagem:** `quay.io/adorsys/keycloak-config-cli:<cli-version>-<keycloak-major>` — alinhar com major.minor do Keycloak no chart (26.x). Bump da imagem do Keycloak exige bump correspondente do CLI.
- **`IMPORT_MANAGED_CLIENT: full`** — clients são totalmente reconciliados (incluindo mappers, service accounts, scopes, redirect URIs). Frente principal do gap descoberto.
- **`IMPORT_MANAGED_USER: no-delete`** — preserva usuários criados manualmente, sessões ativas, password rotations.
- **`IMPORT_MANAGED_AUTHENTICATION_FLOW: no-delete`** — mantém fluxos custom adicionados via Admin UI sem interferir.
- **`IMPORT_MANAGED_GROUP / ROLE / COMPONENT: no-delete`** — defesa em profundidade contra perda acidental de membership/role assignments fora do JSON.
- **`IMPORT_VARSUBSTITUTION_ENABLED: true`** — preserva o pattern `${UNIPLUS_PORTAL_CLIENT_SECRET}` já em uso no `realm.json` (substituído em runtime via env vars do Pod, mesmo que o Keycloak faz no `--import-realm` inicial).
- **`KEYCLOAK_AVAILABILITYCHECK_ENABLED: true`** — Job espera Pod do Keycloak ficar disponível antes de tentar reconciliar (cobre janela de rolling restart pós-upgrade).
- **`backoffLimit: 3`** + **`activeDeadlineSeconds: 600`** + **`ttlSecondsAfterFinished: 600`** — failure transitória retenta até 3 vezes; falha persistente expira em 10 min; sucesso limpa o Job em 10 min.
- **`hook-delete-policy: hook-succeeded,before-hook-creation`** — se Job falhar, fica no cluster para inspeção; sucesso remove para não poluir.

### Habilitação por environment

- **`standalone`:** habilitado (cluster vivo com gap demonstrado em #181).
- **`lab-{sp1,sp2}`:** habilitado (lab usa o mesmo realm.json; previne drift quando dev itera no realm).
- **`prod-{sp1,sp2}`:** habilitado (production é o caso onde drift é mais perigoso).
- **`lab-pa1`:** desabilitado (PA1 não roda Keycloak local — Vault Transit only).

## Consequências

### Positivas

- **Drift Git ↔ cluster eliminado** para clients, mappers, roles, scopes, authentication flows declarados no `realm.json`.
- **Procedimento manual `kcadm.sh` deixa de ser dependência operacional recorrente** — vira fallback de emergência apenas (mantido em RUNBOOKS §15.6 passo 1).
- **GitOps end-to-end real:** ArgoCD reconcilia chart → chart reconcilia realm.
- **Idempotente:** Job pode rodar N vezes sem dano.
- **Preservação de side effects:** users, sessões, passwords criados manualmente sobrevivem à reconciliação.

### Negativas

- **Mais uma imagem para auditar/atualizar** (`adorsys/keycloak-config-cli`). Mitigado pela política de tag matching com Keycloak — bump conjunto.
- **Job adiciona ~10s de latência** ao deploy (espera Keycloak ficar disponível + reconciliação). Aceitável.
- **Falha do Job fica visível em ArgoCD** se a Helm hook falhar — operador precisa diagnosticar via `kubectl logs` no Job antes do `hook-delete-policy` remover. Mitigado pela política `hook-succeeded` (Job só some em sucesso).

### Neutras

- **Mudanças no `realm.json` continuam sendo PR-driven.** O Job apenas garante que o estado de Git chega ao cluster; não muda o fluxo de revisão.

## Confirmação

- ✅ Template `apps/keycloak-replica/templates/realm-reconcile-job.yaml` rendering corretamente em standalone.
- ✅ Bloco `keycloak.realmReconcile.*` em `apps/keycloak-replica/values.yaml` com defaults (off por padrão).
- ✅ Override `keycloak.realmReconcile.enabled: true` em `environments/standalone/values.yaml`.
- ⏳ Validação operacional pós-merge: aplicar mudança no `realm.json` (ex.: novo client) → ArgoCD sync → Job roda → `kcadm.sh get clients` mostra o novo client em <2 min.
- ⏳ Re-rodar smoke E2E após o Job estar ativo — espera-se que os mappers M2M permaneçam consistentes mesmo após `kubectl rollout restart deploy/keycloak-replica` (cenário que antes perdia os mappers em re-import).

## Notas operacionais

- **Bump da imagem do Keycloak** (e.g. 26.6.x → 26.7.x): atualizar conjuntamente `keycloak.image.tag` E `keycloak.realmReconcile.image.tag` no `apps/keycloak-replica/values.yaml`. Tags do CLI seguem padrão `<cli-version>-<keycloak-version>` em https://hub.docker.com/r/adorsys/keycloak-config-cli/tags.
- **Job repetido em rolling update do KC:** Helm hook executa em todo `helm upgrade`. ArgoCD com auto-sync faz rolling do Keycloak quando os values mudam — Job reconcilia automaticamente em seguida. Sem intervenção.
- **Fallback de emergência:** RUNBOOKS §15.6 passo 1 (procedure `kcadm.sh` manual) permanece documentado como fallback se o Job falhar persistentemente. Não é mais o procedure padrão.

## Referências

- Issue [#177](https://github.com/unifesspa-edu-br/uniplus-infra/issues/177) — story aberta após smoke #181
- PR [#181](https://github.com/unifesspa-edu-br/uniplus-infra/pull/181) — smoke E2E que descobriu o gap
- PR [#169](https://github.com/unifesspa-edu-br/uniplus-infra/pull/169) — clients M2M (Story #163) cujos mappers ficaram drift
- [adorsys/keycloak-config-cli](https://github.com/adorsys/keycloak-config-cli) — projeto upstream
- [Keycloak issue: realm import skipped on existing realm](https://github.com/keycloak/keycloak/discussions/13146) — comportamento upstream documentado
- ADR-008 — topologia standalone (contexto do realm.json)
