# Architectural Decision Records (ADR)

Este diretório contém as decisões arquiteturais da infraestrutura da plataforma Uni+.

## Convenção

- **Nomenclatura:** `ADR-NNN-slug-em-kebab-case.md` (3 dígitos, alinhada aos demais repositórios do ecossistema Uni+).
- **Idioma:** português do Brasil.
- **Estrutura:** Status, Data, Relacionado, Contexto, Alternativas consideradas, Decisão, Justificativa (opcional), Consequências.

## Índice

| ID | Título | Status | Data | Issue |
|----|--------|--------|------|-------|
| 001 | [Três DCs lógicos e clusters K8s independentes](ADR-001-tres-dcs-logicos-e-clusters-k8s-independentes.md) | ⛔ Superseded | 2026-04-20 → 2026-05-19 | [#17](https://github.com/unifesspa-edu-br/uniplus-infra/issues/17) |
| 002 | [Componentes stateful pesados fora do Kubernetes](ADR-002-componentes-stateful-pesados-fora-do-kubernetes.md) | ✅ Aceito | 2026-04-20 | [#18](https://github.com/unifesspa-edu-br/uniplus-infra/issues/18) |
| 003 | [Gov.br federado via OIDC institucional](ADR-003-govbr-federado-via-oidc-institucional.md) | ✅ Aceito | 2026-04-20 | [#19](https://github.com/unifesspa-edu-br/uniplus-infra/issues/19) |
| 004 | [Borda externa fora do escopo da PoC](ADR-004-borda-externa-fora-do-escopo-da-poc.md) | 🟡 Pendente | 2026-04-20 | [#20](https://github.com/unifesspa-edu-br/uniplus-infra/issues/20) |
| 005 | [Stateful em containers via systemd](ADR-005-stateful-em-containers-via-systemd.md) | ✅ Aceito | 2026-04-20 | [#21](https://github.com/unifesspa-edu-br/uniplus-infra/issues/21) |
| 006 | [GitOps com ArgoCD](ADR-006-gitops-com-argocd.md) | ✅ Aceito | 2026-04-20 | [#16](https://github.com/unifesspa-edu-br/uniplus-infra/issues/16) |
| 007 | [Vault HA com auto-unseal Transit centralizado em PA1](ADR-007-vault-ha-storage-unseal.md) | ⛔ Superseded | 2026-05-03 → 2026-05-19 | [#13](https://github.com/unifesspa-edu-br/uniplus-infra/issues/13) |
| 008 | [Topologia `standalone` como modelo paralelo provider-agnostic](ADR-008-topologia-standalone.md) | ⛔ Substituída pela 015 | 2026-05-03 | [#47](https://github.com/unifesspa-edu-br/uniplus-infra/issues/47) |
| 009 | [Kafka com SASL_SSL, SCRAM-SHA-512 e StandardAuthorizer](ADR-009-kafka-sasl-ssl-scram.md) | ✅ Aceito | 2026-05-07 | [#138](https://github.com/unifesspa-edu-br/uniplus-infra/issues/138) |
| 010 | [Reconciliação automática do realm Keycloak via keycloak-config-cli](ADR-010-keycloak-config-cli-realm-reconcile.md) | ✅ Aceito | 2026-05-07 | — |
| 011 | [Loki em SingleBinary com armazenamento S3 no MinIO](ADR-011-loki-singlebinary-s3-minio.md) | ✅ Aceito | 2026-05-10 | [#785](https://github.com/unifesspa-edu-br/uniplus-infra/issues/785) |
| 012 | [Tempo em single-binary com armazenamento S3 no MinIO](ADR-012-tempo-singlebinary-s3-minio.md) | ✅ Aceito | 2026-05-10 | [#785](https://github.com/unifesspa-edu-br/uniplus-infra/issues/785) |
| 013 | [OpenTelemetry Collector em DaemonSet único, sem porta no nó](ADR-013-otel-collector-daemonset.md) | ✅ Aceito | 2026-05-10 | [#785](https://github.com/unifesspa-edu-br/uniplus-infra/issues/785) |
| 014 | [Custódia do Vault por Shamir manual](ADR-014-vault-shamir-manual.md) | ✅ Aceito | 2026-07-13 | [#439](https://github.com/unifesspa-edu-br/uniplus-infra/issues/439) |
| 015 | [Produção em duas VMs, TLS entre elas e atualização manual](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md) | ✅ Aceito | 2026-11-07 | [#757](https://github.com/unifesspa-edu-br/uniplus-infra/issues/757) |
| 016 | [Produção lê o repositório de implantação](ADR-016-producao-le-o-repositorio-de-implantacao.md) | ✅ Aceito (sync substituído pela 017) | 2026-11-09 | — |
| 017 | [Produção aplicada pelo pipeline na VM de automação](ADR-017-producao-aplicada-pelo-pipeline-na-vm-de-automacao.md) | ✅ Aceito | 2026-11-11 | [#779](https://github.com/unifesspa-edu-br/uniplus-infra/issues/779) |
