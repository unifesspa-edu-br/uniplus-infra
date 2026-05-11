# ADR-011 — Loki em modo SingleBinary com storage S3-MinIO em standalone

- **Status:** Accepted
- **Data:** 2026-05-10
- **Sub-issue:** [#28 task(observability): completar Helm chart wrapper para Loki](https://github.com/unifesspa-edu-br/uniplus-infra/issues/28)
- **Refs:** ADR-007 (Vault HA), ADR-008 (topologia standalone), [#3 — umbrella plataforma], [#4 — ADR data layer (pendente)]

## Contexto

A plataforma Uni+ precisa de agregação de logs estruturados acessível via Grafana. O backlog de observabilidade tem três sub-issues sequenciais:

- **#28 Loki** (este ADR) — destino + retenção dos logs
- **#29 Tempo** — destino dos traces
- **#30 OTel Collector** — agente coletor de logs (DaemonSet) + gateway de traces

Antes desta entrega, o ApplicationSet `uniplus-platform` referenciava `platform/observability/loki/` mas o diretório só continha um `README.md` placeholder; sync ficava como `Unknown / Healthy` (Argo trata diretório vazio como "nenhum recurso para aplicar"), sem qualquer pod de Loki rodando. Resultado prático: logs dos pods só sobreviviam no `containerd` (`/var/log/containers/*.log`) com rotação curta — qualquer debug pós-incidente exigia SSH ao k8s-host.

O ambiente standalone roda em **single-cluster** (`k8s-host` única VM com K3s 1.31), com volumetria esperada baixa (POC + smoke test de APIs), bucket MinIO `loki-chunks` já provisionado em PR #135 e credencial dedicada `loki-svc` (policy escopada `loki-rw`) custodiada em Vault `secret/standalone/minio/loki` (criada em spike Fase 1 — 2026-05-10).

Em prod (sp1, sp2), a topologia ativo-ativo da plataforma (ADR-007) e a maior volumetria justificarão um **deploymentMode mais robusto**, mas standalone não é o lugar pra essa complexidade.

## Decisão

Para **standalone**:

1. **`deploymentMode: SingleBinary`** com `singleBinary.replicas: 1`.
2. **Storage backend S3-compatible** apontando para o MinIO local (data-host `10.0.2.87:9000`) com:
   - bucket `loki-chunks` (compartilhado entre chunks, ruler e admin — OSS Loki não usa `admin`)
   - credencial dedicada `loki-svc` (policy `loki-rw` escopada apenas a esse bucket)
   - `s3ForcePathStyle: true` (MinIO exige path-style; sem isso falha com "InvalidBucketName")
   - `insecure: true` (HTTP no tráfego intra-VPC; TLS terminado no Traefik para acesso externo)
3. **Schema TSDB v13** com índice `loki_index_` período 24h. TSDB é a recomendação atual do Loki desde 2.8 (substitui boltdb-shipper).
4. **Replication factor 1** em `commonConfig`. Default upstream (3) requer 3 réplicas; com 1 réplica do SingleBinary, default falha com `not enough ingesters` no startup.
5. **Retention 168h (7 dias)** em `limits_config.retention_period`, ativada via `compactor.retention_enabled: true`. Compactor varre os índices a cada ciclo e marca chunks fora da janela para deleção. Sem isso, o bucket cresce indefinidamente.
6. **Componentes auxiliares desligados**: `gateway`, `chunksCache` (memcached), `resultsCache` (memcached), `monitoring`, `lokiCanary`, `test`, `read/write/backend` (componentes do `SimpleScalable`). Cada um tem trade-off claro abaixo.
7. **Credenciais via env-expand**: o binário Loki suporta `-config.expand-env=true` (CLI flag) que substitui `${VAR_NAME}` em qualquer string da config. As credenciais MinIO ficam num `Secret` K8s sintetizado pelo `ExternalSecret` apontando para o Vault, e o `singleBinary.extraEnvFrom` injeta esse Secret como env vars no pod.
8. **NetworkPolicy escopada**: ingress permitido apenas dos namespaces `observability-grafana` (consumidor de query) e `observability-otel-collector` (futuro push de logs em #30); egress permitido para MinIO (`10.0.2.87:9000`) + DNS K8s. Sem ingress externo (Loki não tem UI própria — acesso via Grafana datasource).

Para **prod-{sp1, sp2}**: este ADR não fixa decisão; ficará em ADR separada quando #4 (data layer) e a política de observabilidade multi-DC forem fechadas. Provavelmente `SimpleScalable` com bucket per-DC e retention por classe de log.

## Consequências

### Positivas

- **Sync ArgoCD** sai de `Unknown` para `Synced/Healthy` no standalone — chart wrapper válido.
- **Logs persistidos** com retenção declarativa de 7 dias em standalone (vs ~horas que o containerd retém).
- **Custo zero adicional**: reusa o MinIO standalone que já existe; bucket `loki-chunks` já estava criado.
- **Surface mínima**: 1 pod em vez de 5+ que o `SimpleScalable` exigiria. Operacional simples para POC.
- **Credenciais fora do Git**: Vault custodia o secret; ESO sintetiza em runtime; rotação documentada em `12-vault-rotacao.md` §3.

### Negativas / aceitas

- **Replication factor 1** = sem redundância de ingesters. Perda do pod (crash) entre `chunk_idle_period` e `chunk_target_size` ser atingido perde ~5min de logs em buffer. Aceitável em POC standalone; inaceitável em prod (mas prod ≠ standalone — escopo separado).
- **Caches off** = cada query bate direto no S3. Latência de query primeira (cold) maior; aceitável em standalone (volumetria baixa, baixa frequência de query interativa). Em prod com `chunksCache` + `resultsCache` (memcached) compensa.
- **Sem gateway** = Grafana fala direto com o Service do Loki (não com o nginx que distribui entre componentes do SimpleScalable). Em SingleBinary não há o que distribuir, então gateway só adicionaria hop. Decisão revisitada se virar SimpleScalable.
- **Sem ServiceMonitor** = Prometheus não scrape ainda. Gate por env (`serviceMonitor.enabled: true` no environment standalone quando o stack maturar). Issue follow-up registrada nos comentários do PR.
- **Sem Promtail/Alloy ainda** = sem agente de coleta. Sub-task de #30 (OTel Collector como log shipper via filelog receiver). Loki só responde a `/loki/api/v1/push` quando `otel-collector` for entregue.

### Riscos remanescentes

- **Loki upstream 7.0.0 / app 3.6.7** é major recente. Validamos com `helm template` que o render é coerente; smoke pós-merge confirma startup. Se aparecer regressão de S3-backend, fallback documentado no ADR é downgrade para `6.55.0` (mesmo app version, chart maturo).
- **TSDB schema** muda esquema de índice em alguns minor releases. Mitigação: `schemaConfig` declara `from: 2026-01-01` — mudanças futuras adicionam novos blocos `from` sem rewrite do passado.
- **ExternalSecret refresh 1h** — rotação imediata de credencial MinIO exige `force-sync` annotation manual ou aguardar até 1h. Documentado em `12-vault-rotacao.md` §4.

## Alternativas consideradas

| Alternativa | Por que não |
|---|---|
| **`SimpleScalable` (read+write+backend separados)** | Overhead de 5+ pods em single-node, sem ganho de escala. Apropriado a partir de ~10s de GB/dia (docs upstream). Standalone fica em ordem de MB/dia. |
| **`Distributed` (microservices Loki)** | Idem `SimpleScalable` × 10. Solução para Loki >100GB/dia ou multi-tenant pesado. |
| **Promtail no lugar de OTel Collector com filelog** | Promtail está em soft-deprecation (Grafana Labs recomenda Alloy desde 2024). Já vamos ter OTel Collector para traces (#30); receivers filelog do OTel cobrem a função de Promtail sem agregar componente. Decisão de "OTel-as-shipper" será formalizada em ADR no PR de #30. |
| **Storage local (filesystem) em PVC** | Sem retention multi-DC, sem backup natural, não escala além do disco do node. Aceitável só pra "demo offline"; não para POC de produção. |
| **Bucket dedicado `loki-chunks-standalone` em vez do compartilhado** | Bucket name é per-DC quando #12 (replicação MinIO multi-DC) entregar — para standalone hoje, reusar `loki-chunks` que já existe. Quando #12 fechar, ADR separado fixa nomeclatura `<bucket>-<dc>`. |

## Validação

- `helm lint platform/observability/loki/` ✓
- `helm template -f environments/standalone/values.yaml` ✓ (NetworkPolicy + ExternalSecret + StatefulSet renderizados)
- `kubeconform -strict -summary` ✓ (esperado verde no CI)
- Smoke pós-merge: pod `Running 1/1`, push de log via `curl POST /loki/api/v1/push` aceita 204, query devolve a entry, objeto aparece no `mc ls s/loki-chunks/`.

## Referências

- [Loki Helm chart 7.x docs](https://grafana.com/docs/loki/latest/setup/install/helm/install-monolithic/)
- [Loki storage config](https://grafana.com/docs/loki/latest/configure/#storage_config)
- [Loki TSDB schema](https://grafana.com/docs/loki/latest/operations/storage/tsdb/)
- [External Secrets Operator — ClusterSecretStore](https://external-secrets.io/latest/api/clustersecretstore/)
- ADR-007 — Vault HA storage unseal (consumido pelo ESO)
- ADR-008 — Topologia standalone monolocal
