# Architectural Decision Records (ADR)

Este diretório contém as decisões arquiteturais da infraestrutura da plataforma Uni+.

## Convenção

- **Nomenclatura:** `ADR-NNN-slug-em-kebab-case.md` (3 dígitos, alinhada aos demais repositórios do ecossistema Uni+).
- **Idioma:** português do Brasil.
- **Estrutura:** Status, Data, Relacionado, Contexto, Alternativas consideradas, Decisão, Justificativa (opcional), Consequências.

## Índice

| ID | Título | Status | Data | Issue |
|----|--------|--------|------|-------|
| 001 | [Três DCs lógicos e clusters K8s independentes](ADR-001-tres-dcs-logicos-e-clusters-k8s-independentes.md) | ✅ Aceito | 2026-04-20 | [#17](https://github.com/unifesspa-edu-br/uniplus-infra/issues/17) |
| 002 | [Componentes stateful pesados fora do Kubernetes](ADR-002-componentes-stateful-pesados-fora-do-kubernetes.md) | ✅ Aceito | 2026-04-20 | [#18](https://github.com/unifesspa-edu-br/uniplus-infra/issues/18) |
| 003 | [Gov.br federado via OIDC institucional](ADR-003-govbr-federado-via-oidc-institucional.md) | ✅ Aceito | 2026-04-20 | [#19](https://github.com/unifesspa-edu-br/uniplus-infra/issues/19) |
| 004 | [Borda externa fora do escopo da PoC](ADR-004-borda-externa-fora-do-escopo-da-poc.md) | 🟡 Pendente | 2026-04-20 | [#20](https://github.com/unifesspa-edu-br/uniplus-infra/issues/20) |
| 005 | [Stateful em containers via systemd](ADR-005-stateful-em-containers-via-systemd.md) | ✅ Aceito | 2026-04-20 | [#21](https://github.com/unifesspa-edu-br/uniplus-infra/issues/21) |
| 006 | [GitOps com ArgoCD](ADR-006-gitops-com-argocd.md) | ✅ Aceito | 2026-04-20 | [#16](https://github.com/unifesspa-edu-br/uniplus-infra/issues/16) |
| 007 | [Vault HA com auto-unseal Transit centralizado em PA1](ADR-007-vault-ha-storage-unseal.md) | ✅ Aceito | 2026-05-03 | [#13](https://github.com/unifesspa-edu-br/uniplus-infra/issues/13) |
