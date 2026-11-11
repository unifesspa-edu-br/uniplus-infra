# ADR-013: OpenTelemetry Collector em DaemonSet único, sem porta no nó

- **Status:** ✅ Aceito
- **Data:** 2026-05-10 · revisada em 2026-11-11
- **Relacionado:** [Issue #785](https://github.com/unifesspa-edu-br/uniplus-infra/issues/785) · [ADR-011](ADR-011-loki-singlebinary-s3-minio.md) · [ADR-012](ADR-012-tempo-singlebinary-s3-minio.md) · [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md)

## Contexto

As APIs emitem OTLP (traces, métricas e logs) e os contêineres escrevem logs em arquivo. Os
ambientes `uniplus-hml` e `uniplus-prd` têm um nó só, então um coletor por nó faz o papel de agente
(lê os arquivos) e de gateway (recebe OTLP) ao mesmo tempo.

## Decisão

1. **Um DaemonSet** que é agente e gateway. Release `platform-observability-otelcol` no namespace
   `observability-otelcol`, com `fullnameOverride: otelcol`: o nome gerado estoura 63 caracteres e
   o alias em camelCase viola o DNS-1035. O Service é `otelcol`, portas 4317 e 4318.
2. **Sem `hostPort`.** O OTLP não tem autenticação, e o `hostPort` o exporia no IP do nó, que em
   produção é público. As aplicações usam o Service ClusterIP
   `otelcol.observability-otelcol.svc.cluster.local`.
3. **Imagem contrib**, porque a distribuição `k8s` não traz o exporter `prometheusremotewrite`.
4. **Presets** `logsCollection` (filelog sobre os logs do nó) e `kubernetesAttributes`
   (enriquecimento com pod e namespace). A configuração é `alternateConfig`, que substitui a padrão
   do chart por inteiro.
5. **Pipelines:** logs (filelog e OTLP) para o Loki, em `/otlp`; traces (OTLP) para o Tempo, na
   porta 4318; métricas (OTLP) para o Prometheus por remote write. O atributo `cluster` é
   `uniplus` em todos os sinais.
6. **Endpoints por variável de ambiente** (`extraEnvs`): o `alternateConfig` é renderizado no
   escopo do subchart e não enxerga os values do wrapper. O ambiente define as três, com os
   Services `platform-observability-loki`, `platform-observability-tempo` e
   `platform-observability-pro-prometheus`.
7. **Receivers só OTLP**, sem Jaeger nem Zipkin. Logs de plataforma ruidosos (a probe do Apicurio)
   são descartados antes do batch.
8. **NetworkPolicy fechada:** ingress só dos namespaces que enviam OTLP (`uniplus`, `geo`,
   `traefik`, `keycloak-replica`); egress só para Loki, Tempo, Prometheus, DNS e o kube-apiserver,
   cujo IP (`kubeApiCidrs`) o ambiente informa, porque o egress é avaliado depois do DNAT.

## Alternativas consideradas

- **Deployment como gateway e DaemonSet como agente:** dois componentes sem ganho com um nó só.
  Rejeitada.
- **Aplicações enviando direto aos backends:** cada API precisaria conhecer três endpoints e a
  rede de cada backend. Rejeitada.
- **`hostPort` para as aplicações alcançarem o coletor pelo IP do nó:** expõe OTLP sem
  autenticação fora do cluster. Rejeitada.

## Consequências

- Com dois nós, as aplicações continuam usando o Service, que balanceia entre os coletores; o
  `filelog` de cada nó segue lendo só o próprio.
- A imagem contrib é maior que a `k8s`.
- Um namespace novo que envie OTLP precisa entrar em `ingressNamespaces`.
