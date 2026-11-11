# ADR-011: Loki em SingleBinary com armazenamento S3 no MinIO

- **Status:** ✅ Aceito
- **Data:** 2026-05-10 · revisada em 2026-11-11
- **Relacionado:** [Issue #785](https://github.com/unifesspa-edu-br/uniplus-infra/issues/785) · [ADR-012](ADR-012-tempo-singlebinary-s3-minio.md) · [ADR-013](ADR-013-otel-collector-daemonset.md) · [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md)

## Contexto

Os logs dos contêineres só sobrevivem no nó, com rotação curta, e investigar um incidente depois
do fato exige acesso à VM. Os ambientes `uniplus-hml` e `uniplus-prd` têm um cluster K3s só, com
volumetria baixa, e o MinIO roda fora do cluster, no host de dados, por TLS com o certificado
`*.unifesspa.edu.br` (ADR-015).

## Decisão

1. **SingleBinary, uma réplica**, com `replication_factor: 1`, sem gateway nem caches. Release
   `platform-observability-loki` no namespace `observability-loki`; o Service
   `platform-observability-loki` atende na porta 3100.
2. **Armazenamento S3 no MinIO do host de dados**, pelo nome do host na porta 9000, com TLS
   validado (`insecure: false`) e path-style. Bucket `loki-chunks`.
3. **Credencial própria e mínima:** usuário `loki-svc` com a política `loki-rw`, restrita ao
   bucket. A credencial vive no Vault em `plataforma/minio/loki` e chega ao pod por ExternalSecret
   (store `plataforma`) e `-config.expand-env`. `provisionar-observabilidade.sh` cria o usuário, a
   política e o segredo.
4. **TSDB v13, retenção de 168 horas**, aplicada pelo compactor; sem ele o bucket cresce sem limite.
5. **Entrada por OTLP.** O OTel Collector envia logs para `/otlp` (ADR-013); não há Promtail.
6. **NetworkPolicy fechada:** ingress só de `observability-grafana` e `observability-otelcol`;
   egress só para o MinIO, o DNS e, quando informado, o kube-apiserver. O IP do host de dados
   (`minioCIDR`) não tem default: o ambiente o informa e o chart falha sem ele.
7. **Configuração do wrapper em `lokiWrapper`**, porque o arquivo de values do ambiente é
   compartilhado entre os charts e chaves homônimas colidiriam.

## Alternativas consideradas

- **SimpleScalable ou Distributed:** vários pods sem ganho nesta volumetria. Rejeitadas.
- **Promtail ou Alloy como agente:** o OTel Collector já coleta traces e métricas e cobre os logs
  com o `filelog`. Rejeitadas.
- **Armazenamento em disco local:** sem separação do estado e limitado ao disco do nó. Rejeitada.

## Consequências

- Uma réplica só: um crash perde os logs ainda em memória e o Loki fica indisponível durante o
  restart. Aceito para esta volumetria.
- Sem caches, a primeira consulta de um intervalo lê direto do MinIO.
- Rotacionar a credencial exige regravar o Vault e esperar o refresh do ExternalSecret (1 hora) ou
  forçá-lo.
- A retenção de 7 dias é uma decisão operacional, ajustável por ambiente.
