# ADR-012: Tempo em single-binary com armazenamento S3 no MinIO

- **Status:** ✅ Aceito
- **Data:** 2026-05-10 · revisada em 2026-11-11
- **Relacionado:** [Issue #785](https://github.com/unifesspa-edu-br/uniplus-infra/issues/785) · [ADR-011](ADR-011-loki-singlebinary-s3-minio.md) · [ADR-013](ADR-013-otel-collector-daemonset.md) · [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md)

## Contexto

Sem traces, a latência entre a API, o Keycloak e os serviços de dados só aparece como a soma dos
logs. Os ambientes `uniplus-hml` e `uniplus-prd` têm um cluster K3s só e volumetria baixa; o MinIO
roda no host de dados, por TLS (ADR-015). O desenho segue o do Loki (ADR-011).

## Decisão

1. **Chart `grafana/tempo` em single-binary, uma réplica.** Release `platform-observability-tempo`
   no namespace `observability-tempo`; o Service `platform-observability-tempo` atende a consulta
   na porta 3200 e o OTLP nas portas 4317 (gRPC) e 4318 (HTTP).
2. **Armazenamento S3 no MinIO do host de dados**, com TLS validado (`insecure: false`) e
   path-style. Bucket `tempo-traces`, usuário `tempo-svc` com a política `tempo-rw` restrita a ele.
   A credencial vive no Vault em `plataforma/minio/tempo` e chega por ExternalSecret (store
   `plataforma`); `provisionar-observabilidade.sh` a cria.
3. **Só receivers OTLP.** Jaeger e OpenCensus ficam desligados; as APIs e o OTel Collector
   emitem OTLP.
4. **Retenção de 72 horas.**
5. **Service map e métricas RED** pelo `metricsGenerator`, com remote write para o Prometheus
   (que aceita o receiver de remote write). É opcional: o ambiente liga o gerador, define os
   processors `service-graphs` e `span-metrics` e libera o egress ao namespace do Prometheus na
   NetworkPolicy. Os dashboards de service map dependem disso.
6. **NetworkPolicy fechada:** ingress só de `observability-grafana` e `observability-otelcol`;
   egress só para o MinIO, o DNS, o Prometheus (quando informado) e o kube-apiserver (quando
   informado). `minioCIDR` não tem default e o chart falha sem ele.
7. **Configuração do wrapper em `tempoWrapper`**, pelo mesmo motivo de `lokiWrapper`.

## Alternativas consideradas

- **`tempo-distributed`:** só se justifica com milhares de spans por segundo. Rejeitada.
- **Jaeger com Elasticsearch ou Cassandra:** mais um armazenamento a operar. Rejeitada.
- **Armazenamento em disco local:** sem separação do estado. Rejeitada.

## Consequências

- Uma réplica só: um crash perde os spans ainda em memória.
- Os traces de mais de 72 horas não existem; uma investigação posterior precisa de outra fonte.
- O service map só funciona com o `metricsGenerator` ligado e o remote write liberado.
