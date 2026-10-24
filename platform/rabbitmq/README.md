# rabbitmq

RabbitMQ de um nó com quorum queues, fila de trabalho entre a API e o verificador
de arquivos do candidato
([ADR-0146](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0146-cifra-e-verificacao-dos-arquivos-do-candidato-no-armazenamento.md)
do uniplus-api, issue `uniplus-infra#682`).

## Por que um chart próprio

Não há RabbitMQ Cluster Operator no cluster, e os charts Bitnami deixaram de
publicar imagens gratuitas. O chart usa a imagem oficial `rabbitmq` (a mesma da
POC do uniplus-api#2045). Quorum queues funcionam com um nó; o cluster de três
nós de produção é uma issue à parte.

## O que ele cria

- StatefulSet `rabbitmq` (1 réplica, PVC), Service `rabbitmq` na porta 5672
  (`rabbitmq.<namespace>.svc.cluster.local`), gerência em 15672 (só dentro do
  cluster) e métricas Prometheus em 15692.
- Job de provisionamento (hook pós-sync, pela API de gerência): vhost
  `verificacao` com `default_queue_type=quorum` e os usuários separados:
  - `uniplus-api`: publica pedidos e consome resultados;
  - `uniplus-verificador`: consome pedidos e publica resultados.
  As permissões são `.*` dentro do vhost até a topologia (inclusive a fila de
  erro) estar fechada em uniplus-api#2054.
- ExternalSecrets: as senhas vêm do Vault (`secret/standalone/rabbitmq/{admin,api,verificador}`,
  chaves `username` e `password`). Para os consumidores, o chart cria no
  namespace `uniplus` os Secrets `rabbitmq-api` e `rabbitmq-verificador`, com
  `RABBITMQ_URI`, `RABBITMQ_USERNAME` e `RABBITMQ_PASSWORD`.
- NetworkPolicy: o AMQP só alcança os pods listados em `networkPolicy.clients`.

As senhas são geradas por `scripts/hml-standalone-single/provision-verificacao-prerequisites.sh`.
