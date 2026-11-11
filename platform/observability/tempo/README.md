# observability/tempo

Armazenamento de traces. Wrapper sobre `grafana/tempo` em single-binary, com receivers OTLP e
armazenamento S3 no MinIO do host de dados. Decisão:
[ADR-012](../../../docs/adrs/ADR-012-tempo-singlebinary-s3-minio.md).

**Versão empacotada:** tempo 1.24.4 (Tempo 2.9.0).

## Visão geral

- **Modo:** single-binary, 1 réplica.
- **Armazenamento:** bucket `tempo-traces` no MinIO, por TLS (`insecure: false`), com o usuário
  `tempo-svc` e a política `tempo-rw`. A credencial vem do Vault (`plataforma/minio/tempo`).
- **Receivers:** só OTLP, gRPC 4317 e HTTP 4318. **Retenção:** 72h.
- **Acesso:** Service `platform-observability-tempo` no namespace `observability-tempo`: consulta na
  porta 3200 (Grafana) e OTLP nas portas 4317 e 4318 (OTel Collector).

## Estrutura

```
platform/observability/tempo/
├── Chart.yaml
├── values.yaml
├── values.schema.json
└── templates/
    ├── _helpers.tpl
    ├── externalsecret.yaml   # tempoWrapper.externalSecrets
    └── networkpolicy.yaml    # tempoWrapper.networkPolicy
```

Os valores do subchart ficam em `tempo:` (sem alias). Os do wrapper ficam em `tempoWrapper:`.

## O que o ambiente define

```yaml
tempo:
  persistence:
    storageClassName: <StorageClass>   # este subchart usa storageClassName, não storageClass
  tempo:
    extraEnvFrom:
      - secretRef:
          name: tempo-s3-creds
tempoWrapper:
  externalSecrets:
    enabled: true
  networkPolicy:
    enabled: true
    minioCIDR: <IP do host de dados>/32   # obrigatório com a política ligada
    kubeApiCidrs: [<IP do host do cluster>/32]
```

Para o service map e as métricas RED, o ambiente também liga `tempo.tempo.metricsGenerator` com
`remoteWriteUrl`
(`http://platform-observability-pro-prometheus.observability-prometheus.svc.cluster.local:9090/api/v1/write`),
os processors `service-graphs` e `span-metrics` em `tempo.tempo.overrides.defaults.metrics_generator`,
e `tempoWrapper.networkPolicy.egressPrometheusNamespace: observability-prometheus`.

## Particularidades do subchart

- `tempo.tempo.extraArgs` é mapa: `config.expand-env: "true"` vira `-config.expand-env=true`.
- O parâmetro S3 é `forcepathstyle`, e não `s3ForcePathStyle` como no Loki.
- `tempoQuery` fica desligado: a consulta é pelo Grafana.

## Validação

```bash
helm dependency update platform/observability/tempo
helm template platform-observability-tempo platform/observability/tempo \
  -f environments/uniplus-prd/values.yaml --namespace observability-tempo
```

## Conferência depois do sync

```bash
kubectl -n observability-tempo get pods
kubectl -n observability-tempo port-forward svc/platform-observability-tempo 3200:3200 &
curl -s http://127.0.0.1:3200/ready
```

## Referências

- [Tempo Helm chart](https://grafana.com/docs/tempo/latest/setup/helm-chart/)
- [Configuração do Tempo](https://grafana.com/docs/tempo/latest/configuration/)
- [ADR-012](../../../docs/adrs/ADR-012-tempo-singlebinary-s3-minio.md) e [ADR-011](../../../docs/adrs/ADR-011-loki-singlebinary-s3-minio.md)
