# external-secrets

External Secrets Operator (ESO) — sincroniza Secrets do Vault para Secrets nativos do K8s.

## Visão geral

Wrapper do chart oficial [external-secrets/external-secrets](https://github.com/external-secrets/external-secrets). Roda no cluster do ambiente e consome Secrets do Vault de aplicação local (chart `platform/vault/`).

**Upstream:** https://github.com/external-secrets/external-secrets
**Versão upstream empacotada:** v2.4.1 (ver `Chart.yaml`)

## Estrutura

```
platform/external-secrets/
├── Chart.yaml                              # subchart upstream
├── values.yaml                             # defaults Uni+
├── values.schema.json                      # validação dos overrides
├── README.md                               # este arquivo
└── templates/
    ├── clustersecretstore-vault.yaml       # uma ClusterSecretStore + ServiceAccount por sistema (gated)
    └── networkpolicy.yaml                  # egress controlado
```

ServiceMonitors vêm do subchart upstream (controller, webhook, cert-controller), gateados por `externalSecrets.serviceMonitor.enabled`. O wrapper não emite SM próprio para evitar scrape duplicado.

## Isolamento por sistema

Há um KV v2 do Vault por sistema e ambiente (`uniplus-<amb>`, `geo-<amb>`, `plataforma-<amb>`) e uma `ClusterSecretStore` por KV. Cada store:

- lê só o próprio KV (política `external-secrets-<store>` no Vault);
- autentica com um papel Kubernetes e uma ServiceAccount próprios em `external-secrets`;
- declara `spec.conditions[].namespaces` com os únicos namespaces do dono.

Um `ExternalSecret` fora desses namespaces é recusado pelo ESO, e nenhum Secret é criado. Os charts guardam só o nome da store (`uniplus`, `geo` ou `plataforma`) e o caminho interno do segredo (ex.: `postgres`, `rabbitmq/api`); o KV vem do arquivo do ambiente. O mapa de caminhos está em [`docs/vault-caminhos.md`](../../docs/vault-caminhos.md).

## Bootstrap

Após o ApplicationSet sincronizar e os Pods do operator subirem, as stores permanecem **desligadas** até que o Vault esteja inicializado, aberto e configurado.

1. Inicializar e abrir o Vault (Shamir 5/3), fora dos scripts.
2. Rodar `scripts/servicos-no-host/configurar-vault.sh`: monta os três KVs, habilita o auth Kubernetes e cria uma política e um papel por store.
3. Habilitar as stores no arquivo do ambiente:

   ```yaml
   # environments/uniplus-prd/values.yaml
   clusterSecretStore:
     enabled: true
     vaultServer: https://uniplus-vault.unifesspa.edu.br:8200
     stores:
       - name: uniplus
         vaultPath: uniplus-prd
         namespaces: [uniplus]
       - name: geo
         vaultPath: geo-prd
         namespaces: [geo]
       - name: plataforma
         vaultPath: plataforma-prd
         namespaces: [kes, kafka-ui, redis-ui]
   ```

4. O ArgoCD reconcilia e cada store fica `Ready`.

## Variáveis principais

| Variável | Default | Notas |
|---|---|---|
| `external-secrets.replicaCount` | `1` | 1 num nó só, 2+ para alta disponibilidade |
| `external-secrets.serviceMonitor.enabled` | `false` | Ligar quando houver Prometheus |
| `clusterSecretStore.enabled` | `false` | Habilitar APÓS Vault init + `configurar-vault.sh` |
| `clusterSecretStore.vaultServer` | _(vazio)_ | `https://<nome público do Vault>:8200`, resolvido para o Service pelo CoreDNS |
| `clusterSecretStore.stores[]` | `[]` | `name`, `vaultPath`, `namespaces` (obrigatórios); `role` e `serviceAccount` (default `external-secrets-<name>`) |
| `networkPolicy.enabled` | `true` | Egress restrito a Vault + DNS + K8s API |

## Exemplo de consumo (ExternalSecret)

```yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: postgres
  namespace: uniplus
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: uniplus                # nome da ClusterSecretStore do sistema
    kind: ClusterSecretStore
  target:
    name: postgres               # K8s Secret resultante
  data:
    - secretKey: password
      remoteRef:
        key: postgres            # caminho no KV: uniplus-prd/data/postgres
        property: password
```

O mesmo ExternalSecret no namespace `geo` é recusado: a store `uniplus` só atende `uniplus`.

## Observabilidade

ESO expõe métricas Prometheus na porta `8080`. Os ServiceMonitors são gerados pelo subchart quando `external-secrets.serviceMonitor.enabled: true`.

## Network

A NetworkPolicy do chart restringe o egress dos Pods do operator a:

- Vault (TCP 8200);
- kube-dns (UDP/TCP 53);
- Kubernetes API, restrito ao service CIDR.

Sem ingress: o operator não recebe tráfego direto.

## Segurança

- Uma ServiceAccount por store, autenticada no Vault via `auth/kubernetes` (TokenReview).
- Papéis com TTL curto (1h); o ESO renova os tokens.
- Cada política `external-secrets-<store>` é somente leitura no KV da própria store; o ESO nunca escreve no Vault.
- Egress restrito por NetworkPolicy.

## Referências

- [`docs/vault-caminhos.md`](../../docs/vault-caminhos.md) — KVs e caminhos por sistema
- `docs/RUNBOOKS.md` — procedimentos do Vault
