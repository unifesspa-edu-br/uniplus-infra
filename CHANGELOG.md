# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Corrigido

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
