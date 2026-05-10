# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Alterado

- Chart `keycloak-replica` passa a consumir a imagem composta `ghcr.io/unifesspa-edu-br/uniplus-keycloak:26.6.1-0` (Keycloak 26.6.1 + JAR `cpf-matcher`) em vez do upstream vanilla `quay.io/keycloak/keycloak:26.6.1`. Standalone passa a validar exatamente o binário que vai pra HML/PROD (production parity). `appVersion` do Chart sincronizada com a tag composta. Issue #192, depende de `unifesspa-edu-br/uniplus-keycloak-providers#13` (Release `v26.6.1-0` em 2026-05-10).

### Corrigido

- Chart `clamav-scanner` ganha `fsGroupChangePolicy: Always` no `podSecurityContext`. Sem isso, em ambientes com k3s `local-path` provisioner (standalone), o `fsGroup: 100` declarado não era aplicado ao volume montado em `/var/lib/clamav` — o entrypoint da imagem oficial `clamav/clamav:1.4` tentava `chown` antes de fazer drop privileges para uid 100 e falhava com `Operation not permitted` sob `runAsNonRoot: true`, deixando o pod em `CrashLoopBackOff` desde o merge do PR #182. Issue #188.
- `description` dos 5 clients OIDC em `apps/keycloak-replica/files/uniplus-realm.json` (kafka-ui, apicurio-registry, uniplus-api-portal/selecao/ingresso) encurtada para ≤ 255 chars cada. Causa raiz: o schema da tabela `CLIENT` do Keycloak define `DESCRIPTION` como `VARCHAR(255)` desde KC 1.x; `--import-realm` trunca silenciosamente no INSERT inicial, mas `PUT /admin/realms/{r}/clients/{id}` (UPDATE via admin API — usado pelo `keycloak-config-cli`) rejeita com PG `22001 (value too long for type character varying(255))` → reconciliação falha em HTTP 500. Detalhes operacionais longos (procedure `kcadm.sh` para recuperar `client_secret`, semântica dos mappers) movidos para `RUNBOOKS.md`. Issue #196.
- `NetworkPolicy` do chart `keycloak-replica` ganha 3ª regra de ingress permitindo pods com label `uniplus.io/job-role=realm-reconcile` (mesmo namespace) chamarem o KC na porta HTTP. Sem isso, o Job `realm-reconcile` (ADR-010) — embora rodando vizinho ao KC — não conseguia alcançar o Service e morria em timeout/`backoffLimit`. Bug pré-existente do PR #183, mascarado anteriormente pelo `ImagePullBackOff` da issue #192. Escopo cirúrgico (label específica, não abre ingress geral do namespace). Issue #194.
- Tag de `quay.io/adorsys/keycloak-config-cli` em `apps/keycloak-replica/values.yaml` corrigida de `6.4.0-26.0.6` (inexistente — typo histórico do PR #183) para `6.5.0-26.5.4` (mais recente publicada; mesma major do KC vivo, admin API estável). Sem essa correção o Job `realm-reconcile` (ADR-010) ficava em `ImagePullBackOff` indefinidamente, bloqueando reconciliação automática do realm em re-deploy. Issue #192.
- Keycloak client `uniplus-portal` (public + PKCE, frontend Angular) recebe `protocolMapper` `audience-uniplus` (`oidc-audience-mapper` com `included.custom.audience=uniplus`, projetado apenas no access_token). Sem o mapper o token vinha com `aud: ["account"]` e as APIs Uni+ — que validam `Auth__Audience=uniplus` — respondiam 401 a qualquer chamada do frontend. Mitigação manual via `kcadm.sh` foi aplicada durante o smoke #166; agora o mapper está persistido em `apps/keycloak-replica/files/uniplus-realm.json` e o Job `realm-reconcile` (ADR-010, post-install/post-upgrade) o reaplica em re-deploy. Issue #186.

### Adicionado

- Keycloak realm `uniplus` ganha 3 confidential clients para fluxo M2M `client_credentials` — `uniplus-api-portal`, `uniplus-api-selecao`, `uniplus-api-ingresso`. Cada um com `serviceAccountsEnabled=true`, audience mapper para `apicurio-registry` e hardcoded-claim mapper que projeta `groups: ["/users/uniplus"]` (Apicurio mapeia → role `sr-developer`). Destrava `uniplus-api#358` (integração Apicurio Schema Registry). RUNBOOKS §15.6 documenta procedure de recuperação do `client_secret` pós-import. Issue #163.
- Estrutura inicial do repositório uniplus-infra
- Documentação institucional (README, CONTRIBUTING, SECURITY, LICENSE)
- Documentação técnica (ARCHITECTURE, VALIDATION-PLAN, SETUP, RUNBOOKS)
- 6 diagramas C4 (Context, Container, Deployment, Component, 2 Sequence) com fontes PlantUML
- Estrutura de Helm charts em `apps/` e `platform/`
- Configuração de componentes stateful em `data/`
- Ambientes lab-sp1, lab-sp2, lab-pa1, prod-sp1, prod-sp2
- ArgoCD ApplicationSet + AppProject com RBAC
- Scripts de bootstrap, validação e teardown do laboratório
- GitHub Actions CI (yamllint, helm lint, shellcheck, markdown lint)
- Templates de Issue e Pull Request
