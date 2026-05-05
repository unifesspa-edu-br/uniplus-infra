# external-secrets

External Secrets Operator (ESO) — sincroniza Secrets do Vault para Secrets nativos do K8s.

## Visão geral

Wrapper do chart oficial [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets). Roda em cada cluster (lab-{sp1,sp2}, prod-{sp1,sp2}, standalone) e consome Secrets do Vault de aplicação local (chart `platform/vault/`).

Em clusters PA1, ESO permanece desligado por default — PA1 só hospeda Vault Transit (não há aplicação consumindo Secrets ali).

**Upstream:** https://github.com/external-secrets/external-secrets
**Versão upstream empacotada:** v2.4.1 (ver `Chart.yaml`)

## Estrutura

```
platform/external-secrets/
├── Chart.yaml                              # subchart upstream (alias=externalSecrets)
├── values.yaml                             # defaults Uni+
├── values.schema.json                      # validação dos overrides
├── README.md                               # este arquivo
└── templates/
    ├── clustersecretstore-vault.yaml       # CSS default (gated)
    └── networkpolicy.yaml                  # egress controlado
```

ServiceMonitors vêm do subchart upstream (3 — controller/webhook/cert-controller), gateados por `externalSecrets.serviceMonitor.enabled`. Wrapper não emite SM próprio para evitar scrape duplicado.

## Bootstrap

Após o ApplicationSet sincronizar e os Pods do operator subirem, o `ClusterSecretStore` permanece **desligado** até que o Vault esteja inicializado e o role `external-secrets` configurado.

Procedimento (resumido — versão completa em `docs/RUNBOOKS.md` §1.4 e §8.4):

1. Vault inicializado: `kubectl exec vault-0 -n vault -- vault operator init -recovery-shares=5 -recovery-threshold=3`
2. Vault unsealed automaticamente (Transit em SP1/SP2 ou OCI KMS em standalone — issue #64)
3. Habilitar auth Kubernetes no Vault e criar policy + role:

   ```bash
   kubectl exec vault-0 -n vault -- sh -c '
     vault auth enable kubernetes
     vault write auth/kubernetes/config \
       kubernetes_host=https://kubernetes.default.svc.cluster.local
     vault policy write external-secrets-read - <<EOF
   path "secret/data/*" { capabilities = ["read"] }
   path "secret/metadata/*" { capabilities = ["read"] }
   EOF
     vault write auth/kubernetes/role/external-secrets \
       bound_service_account_names=external-secrets \
       bound_service_account_namespaces=external-secrets \
       policies=external-secrets-read \
       ttl=1h
   '
   ```

4. Habilitar o ClusterSecretStore via override no environment:

   ```yaml
   # environments/standalone/values.yaml
   clusterSecretStore:
     enabled: true
   ```

5. ArgoCD reconcilia, ESO valida o store e fica `Ready`.

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `externalSecrets.enabled` | `true` | Liga o subchart |
| `externalSecrets.replicaCount` | `1` | 1 em lab/standalone, 2+ em prod |
| `externalSecrets.serviceMonitor.enabled` | `false` | Ligar quando #26 (Prometheus chart) estiver pronto |
| `clusterSecretStore.enabled` | `false` | Habilitar APÓS Vault init + role configurado |
| `clusterSecretStore.vaultServer` | `http://vault.vault.svc.cluster.local:8200` | Service ClusterIP do chart `platform/vault/` |
| `networkPolicy.enabled` | `true` | Egress restrito a Vault + DNS + K8s API |

## Exemplo de consumo (ExternalSecret)

Após o ClusterSecretStore estar `Ready`, qualquer Pod pode consumir Secrets sintetizados a partir do Vault:

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: portal-postgres-creds
  namespace: uniplus
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: vault-default          # nome do ClusterSecretStore
    kind: ClusterSecretStore
  target:
    name: portal-postgres-creds  # K8s Secret resultante
  data:
    - secretKey: connection-string
      remoteRef:
        key: portal/postgres     # path no KV v2: secret/data/portal/postgres
        property: connection_string
```

A Secret `portal-postgres-creds` aparece no namespace `uniplus` e é consumida pelo Deployment do `apps/uniplus-api-portal` via `envFrom.secretRef`.

## Observabilidade

ESO expõe métricas Prometheus na porta `8080` (default do upstream chart). Os ServiceMonitors são gerados pelo próprio subchart (3 SMs: controller, webhook, cert-controller) quando `externalSecrets.serviceMonitor.enabled: true` — manter desligado até o stack Prometheus (#26) estar no ar. O wrapper não emite SM próprio para evitar scrape duplicado do endpoint `/metrics`.

## Network

NetworkPolicy do chart restringe egress dos Pods do operator a:
- Vault no namespace local (TCP 8200)
- kube-dns (UDP/TCP 53)
- Kubernetes API (TCP 6443/443) restrito ao service CIDR

Sem ingress (operator não recebe tráfego direto — webhook é gerenciado pelo subchart).

## Segurança

- ServiceAccount `external-secrets` autenticada no Vault via `auth/kubernetes` (TokenReview).
- Role TTL curta (1h) — ESO renova tokens automaticamente.
- Policy `external-secrets-read` é **read-only** em `secret/data/*` — ESO nunca escreve no Vault.
- Egress restrito por NetworkPolicy (sem destino livre na internet).

## Referências

- [#3](https://github.com/unifesspa-edu-br/uniplus-infra/issues/3) — umbrella platform charts
- [#24](https://github.com/unifesspa-edu-br/uniplus-infra/issues/24) — esta task
- [#64](https://github.com/unifesspa-edu-br/uniplus-infra/issues/64) — Vault init + auto-unseal OCI KMS (pré-requisito do CSS)
- ADR-007 (Vault HA Raft + Transit auto-unseal)
- ADR-008 (topologia standalone)
- `docs/RUNBOOKS.md` §1.4 e §8.4
