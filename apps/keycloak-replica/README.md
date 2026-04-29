# keycloak-replica

Réplica local do Keycloak institucional para autenticação

> ⚠️ **Status:** placeholder inicial. Implementação dos templates pendente.

## Visão geral

Componente da plataforma Uni+. Veja [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) para contexto.

## Pré-requisitos

- Kubernetes 1.30+
- Helm 3.x
- Vault + External Secrets Operator (para secrets)

## Implementação pendente

- [ ] templates/deployment.yaml
- [ ] templates/service.yaml
- [ ] templates/ingressroute.yaml (se exposto externamente)
- [ ] templates/configmap.yaml
- [ ] templates/externalsecret.yaml
- [ ] templates/networkpolicy.yaml
- [ ] templates/servicemonitor.yaml

Veja [apps/uniplus-web](../uniplus-web/) como referência para estrutura.

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra).
