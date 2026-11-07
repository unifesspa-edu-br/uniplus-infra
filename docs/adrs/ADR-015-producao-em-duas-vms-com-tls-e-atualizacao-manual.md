# ADR-015: Produção em duas VMs, TLS entre elas e atualização manual

- **Status:** ✅ Aceito
- **Data:** 2026-11-07
- **Relacionado:** [Issue #757](https://github.com/unifesspa-edu-br/uniplus-infra/issues/757) · [ADR-002](ADR-002-componentes-stateful-pesados-fora-do-kubernetes.md) · [ADR-005](ADR-005-stateful-em-containers-via-systemd.md) · [ADR-014](ADR-014-vault-shamir-hml-standalone-single.md)

## Contexto

A produção precisa de um ambiente próprio, com o estado fora do Kubernetes (ADR-002) e sem a
sincronização contínua da homologação: uma mudança errada no Git não pode chegar sozinha aos
usuários. Cada VM tem IP público institucional, e o tráfego entre elas passa por uma rede que não
se assume confiável.

## Decisão

1. **Duas VMs.** `uniplus-prod-app` roda o K3s com Traefik, ArgoCD, Vault, External Secrets, KES,
   as APIs, o web e a observabilidade. `uniplus-prod-infra` roda PostgreSQL com PostGIS, MinIO,
   Redis, Kafka e RabbitMQ em containers Docker sob systemd, com os dados em `/var/lib/uniplus`. O
   RabbitMQ sai do cluster.
2. **TLS em todo o tráfego entre as VMs**, com validação do certificado pelo cliente e as portas sem
   TLS desligadas: PostgreSQL (`hostssl` só para a VM de aplicação, `VerifyFull`), Redis (`tls-port`),
   MinIO, Kafka (`SASL_SSL`), RabbitMQ (AMQPS) e o KES, que o MinIO alcança por TLS mútuo. Os serviços
   são alcançados pelo nome `uniplus-prod-infra.unifesspa.edu.br`, coberto pelo certificado curinga
   `*.unifesspa.edu.br` da instituição. Não há CA interna. O par fica nas VMs, fora do Git, e a
   renovação é um script que reinicia cada serviço nas duas VMs.
3. **Atualização manual por tag.** Nenhuma Application de produção tem `syncPolicy.automated`. As
   fontes dos ApplicationSets apontam para o label `uniplus.io/revision` do cluster (uma tag deste
   repositório validada em homologação) e a geração falha sem ele, em vez de seguir `main`. Os
   mesmos ApplicationSets geram a homologação sem mudança de resultado.
4. **Rede.** A infraestrutura só aceita a VM de aplicação, em portas fixas. Rotas de administração
   respondem só à rede institucional e à VPN. A leitura anônima do acervo público é restrita ao IP
   da VM de aplicação (`aws:SourceIp`).

## Alternativas consideradas

- **Uma VM só**, como na homologação: sem separar o estado do cluster e com disputa de recursos.
  Rejeitada.
- **CA interna e mTLS completo:** operação adicional sem ganho sobre o certificado institucional já
  existente, num ambiente com um único cliente por serviço. Rejeitada.
- **Sincronização automática com `main`:** conveniente, mas faz de cada merge um deploy em
  produção. Rejeitada.

## Consequências

- O deploy é um ato deliberado: criar a tag, registrar a revisão, revisar o diff e sincronizar.
- Reiniciar o Vault exige abertura manual (Shamir 5/3), como na homologação.
- Renovar o certificado causa um reinício curto de cada serviço, nas duas VMs.
- O KES exige uma porta a mais na VM de aplicação (7373, só para a VM de infraestrutura).
