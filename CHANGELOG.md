# Changelog

Todas as mudanças notáveis deste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.1.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Não lançado]

### Adicionado

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
