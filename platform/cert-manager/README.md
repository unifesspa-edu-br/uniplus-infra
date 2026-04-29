# cert-manager

Provisionamento automático de certificados TLS (Let's Encrypt)

> ⚠️ **Status:** placeholder inicial.

## Visão geral

Componente de plataforma do cluster Kubernetes do Uni+.

**Upstream:** https://github.com/cert-manager/cert-manager

## Estratégia de deploy

Recomenda-se usar o **chart upstream oficial** quando disponível, ao invés de manter chart próprio. Esta pasta deve conter:

- `Chart.yaml` — chart umbrella ou referência ao chart upstream
- `values.yaml` — valores customizados para o ambiente Uni+
- `README.md` — este arquivo

## Implementação pendente

- [ ] Chart.yaml com dependência do chart upstream
- [ ] values.yaml com configuração base
- [ ] Documentação de configurações específicas
- [ ] ApplicationSet ArgoCD

## Contribuindo

PRs em [unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra).
