# environment lab-standalone-single

Values overlay de referência para a topologia de laboratório de host único
(K3s + Docker na mesma VM) — ver `../../scripts/lab-standalone-single/` para
os componentes stateful (Postgres, Redis, MinIO, Kafka) e a issue
[#395](https://github.com/unifesspa-edu-br/uniplus-infra/issues/395) para o
contexto completo da decomposição.

**Diferente do `standalone-compact`**: não há cluster ArgoCD registrado para
este ambiente — o `values.yaml` aqui é aplicado manualmente
(`helm install/upgrade -f environments/lab-standalone-single/values.yaml`)
durante a implementação das Tasks da issue #395, não via GitOps automático.
Cresce incrementalmente conforme cada componente de plataforma (Vault,
External Secrets Operator, ...) é validado.

## Componentes cobertos até o momento

| Componente | Chart | Notas |
|---|---|---|
| Vault | `platform/vault/` | Single-node (replicas=1), Shamir manual (1 key share, threshold 1 — simplificado para lab), sem peer PA1/OCI KMS |
| External Secrets Operator | `platform/external-secrets/` | `ClusterSecretStore vault-default` apontando para o Vault acima; NetworkPolicy habilitada nos dois charts (ver nota abaixo) |

## Uso

```bash
helm dependency update platform/vault/
helm install vault platform/vault/ -f environments/lab-standalone-single/values.yaml --namespace vault
```

Após o primeiro install, inicializar e desselar manualmente:

```bash
kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1 -format=json
# custodiar a saída (unseal key + root token) fora do repo
kubectl exec -n vault vault-0 -- vault operator unseal <unseal_key>
```

Em seguida, habilitar o auth Kubernetes e criar a policy/role que o ESO usa
(procedimento completo em `platform/external-secrets/README.md`):

```bash
kubectl exec -n vault vault-0 -- sh -c '
  export VAULT_TOKEN=<root_token>
  vault auth enable kubernetes
  vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc.cluster.local
  vault policy write external-secrets-read - <<EOF
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read"] }
EOF
  vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-read \
    ttl=1h
  vault secrets enable -path=secret -version=2 kv
'
```

Depois, instalar o ESO — em duas etapas, porque os CRDs do subchart upstream
vêm como `templates/crds/*.yaml` normais (não a pasta especial `crds/` do
Helm), então não podem coexistir com o `ClusterSecretStore` (CR) no mesmo
`helm install` — o client resolve o kind antes de aplicar qualquer objeto:

```bash
helm dependency update platform/external-secrets/
kubectl create namespace external-secrets
helm install external-secrets platform/external-secrets/ --namespace external-secrets --set clusterSecretStore.enabled=false
# aguardar os pods do ESO Ready, então:
helm upgrade external-secrets platform/external-secrets/ -f environments/lab-standalone-single/values.yaml --namespace external-secrets
```

### NetworkPolicy: kubeApiCidrs precisa do CIDR do host, não só do service CIDR

O k3s do lab embute o `kube-router` como NetworkPolicy controller mesmo
usando flannel como dataplane de pods — ele **enforça** NetworkPolicy, ao
contrário do que se supunha inicialmente. O egress ao Service `kubernetes`
(`10.43.0.1:443`) é avaliado **depois** do DNAT do kube-proxy: em K3s o
apiserver roda como processo no host (não como Pod), então o pacote de
saída já reescrito tem como destino `<ip-da-vm>:6443` — fora do CIDR de
serviço `10.43.0.0/16`. Sem o CIDR do host em `networkPolicy.kubeApiCidrs`,
o controller do ESO, o cert-controller e o webhook ficam em
`CrashLoopBackOff` com `dial tcp 10.43.0.1:443: connect: connection
refused` no `init()` (mesmo bug documentado em
`environments/standalone-compact/values.yaml`, ali com o CIDR da VCN OCI).

Como a chave raiz `networkPolicy` é compartilhada pelo `values.yaml` deste
environment entre os wrappers `platform/vault/` e `platform/external-secrets/`
(cada um lido via `-f` num `helm install/upgrade` separado), habilitá-la
afeta os dois charts — os defaults do chart Vault
(`externalSecretsNamespace: external-secrets`, `traefikNamespace: traefik`)
já batem com os nomes reais usados no lab, então não é necessário overridá-los
aqui.
