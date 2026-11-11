# observability/loki

Agregação de logs. Wrapper sobre `grafana/loki` em modo `SingleBinary`, com armazenamento S3 no
MinIO do host de dados. Decisão: [ADR-011](../../../docs/adrs/ADR-011-loki-singlebinary-s3-minio.md).

**Versão empacotada:** loki 7.0.0 (Loki 3.6.7).

## Visão geral

- **Modo:** `SingleBinary`, 1 réplica, `replication_factor: 1`.
- **Armazenamento:** bucket `loki-chunks` no MinIO, por TLS (`insecure: false`), com o usuário
  `loki-svc` e a política `loki-rw`. A credencial vem do Vault (`plataforma/minio/loki`).
- **Schema:** TSDB v13. **Retenção:** 168h, aplicada pelo compactor.
- **Acesso:** Service `platform-observability-loki` na porta 3100, no namespace `observability-loki`.
  O OTel Collector envia logs para `/otlp`; o Grafana consulta o mesmo Service.

## Estrutura

```
platform/observability/loki/
├── Chart.yaml
├── values.yaml
├── values.schema.json
└── templates/
    ├── _helpers.tpl
    ├── externalsecret.yaml   # lokiWrapper.externalSecrets
    └── networkpolicy.yaml    # lokiWrapper.networkPolicy
```

Os valores do subchart ficam em `loki:` (sem alias). Os do wrapper ficam em `lokiWrapper:`, porque o
arquivo de values do ambiente é compartilhado entre os charts.

## O que o ambiente define

```yaml
loki:
  singleBinary:
    persistence:
      storageClass: <StorageClass>
    extraEnvFrom:
      - secretRef:
          name: loki-s3-creds
lokiWrapper:
  externalSecrets:
    enabled: true
  networkPolicy:
    enabled: true
    minioCIDR: <IP do host de dados>/32   # obrigatório com a política ligada
    kubeApiCidrs: [<IP do host do cluster>/32]
```

O Secret `loki-s3-creds` é fixo porque `extraEnvFrom` do subchart não aceita template. O endpoint e a
região S3 vêm do Vault (`endpoint` e `region`), não dos values.

## Validação

```bash
helm dependency update platform/observability/loki
helm template platform-observability-loki platform/observability/loki \
  -f environments/uniplus-prd/values.yaml --namespace observability-loki
```

## Conferência depois do sync

```bash
kubectl -n observability-loki get pods
kubectl -n observability-loki port-forward svc/platform-observability-loki 3100:3100 &
curl -s http://127.0.0.1:3100/ready
curl -sG http://127.0.0.1:3100/loki/api/v1/labels
```

## Referências

- [Loki Helm chart](https://grafana.com/docs/loki/latest/setup/install/helm/)
- [Esquema TSDB](https://grafana.com/docs/loki/latest/operations/storage/tsdb/)
- [ADR-011](../../../docs/adrs/ADR-011-loki-singlebinary-s3-minio.md) e [ADR-013](../../../docs/adrs/ADR-013-otel-collector-daemonset.md)
