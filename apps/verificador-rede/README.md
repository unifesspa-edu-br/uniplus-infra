# verificador-rede

NetworkPolicy que isola o verificador de arquivos do candidato
([ADR-0146](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0146-cifra-e-verificacao-dos-arquivos-do-candidato-no-armazenamento.md)
do uniplus-api, issue `uniplus-infra#682`). O chart do verificador mora no
uniplus-api (`infra/helm/verificador`); este aqui só traz a política de rede,
porque o isolamento é decisão de infraestrutura e não pode depender do chart da
aplicação.

## O que a política permite

Lista permitida, só saída; nenhuma entrada:

| Destino | Porta | Por quê |
|---|---|---|
| DNS | 53 | resolução dos Services |
| MinIO (IP do host) | 9000 | ler, promover e remover objetos |
| RabbitMQ (namespace `rabbitmq`) | 5672 | pedidos e resultados |
| Espelho da base do antivírus (Service `clamav-espelho`, namespace `uniplus`) | 8080 (porta do pod) | freshclam do clamd sidecar (ADR-0147, #679) |

Tudo o mais é negado: o Postgres (5432, mesmo IP do MinIO) e qualquer endereço
da internet. O clamd roda como sidecar do mesmo pod, em `localhost`, e não passa
pela política.

Esta é a única NetworkPolicy do verificador; o chart do `uniplus-api` não traz nenhuma. Os
pods precisam do label `app.kubernetes.io/name: uniplus-verificador`, o mesmo que a
NetworkPolicy de entrada do espelho exige.

## Valores

Ver `values.yaml`. Em HML, `verificadorRede.minio.cidr` é o IP do host e
`verificadorRede.podSelector` tem de casar com os labels do chart do verificador.
