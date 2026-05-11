# vault-transit-bootstrap

![Version: 0.1.0](https://img.shields.io/badge/Version-0.1.0-informational?style=flat-square)
![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square)
![AppVersion: 1.21.2](https://img.shields.io/badge/AppVersion-1.21.2-informational?style=flat-square)

Bootstrap declarativo do Vault Transit no cluster local. Em todo `helm install` /
`upgrade` / `rollback`, um Job idempotente reconcilia:

1. Mount `transit/` (cria se ausente).
2. Key `uniplus-idempotency-aesgcm` (AES-GCM-256, não-deletável, não-exportável).
3. Policy `uniplus-api-transit` (apenas `update` em `encrypt`/`decrypt` da key).
4. Role Kubernetes auth `uniplus-api` (vinculada à SA `uniplus-api` no namespace
   `uniplus`, com TTL de token 1h).

Pattern espelha `apps/keycloak-replica/templates/realm-reconcile-job.yaml`
(reconciliação declarativa via Helm hook).

## Trade-off de segurança — token do Job

Em standalone, o `ExternalSecret` consome `secret/standalone/vault/root` (root
token do Vault). Isso é deliberadamente excessivo para este escopo
(`sys/mounts`, `transit/*`, `sys/policies/acl`, `auth/kubernetes/role`) e
**precisa ser reduzido antes da Fase 6**. Plano de redução:

1. Operador roda manualmente (RUNBOOK) um script one-shot com root para criar
   uma policy `vault-transit-bootstrap-policy` mínima e emitir um token bootstrap
   periódico vinculado.
2. O token bootstrap é custodiado em `secret/standalone/vault-transit-bootstrap/token`.
3. Override em `environments/standalone/values.yaml`:
   `vaultTransitBootstrap.externalSecret.vaultPath` aponta para o novo path.
4. Root token volta para offline-only.

Issue de seguimento será aberta quando este chart entrar em produção.

## Operações comuns

Sanidade pós-deploy (ver detalhe completo em `docs/RUNBOOKS.md`):

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<k8s-host>
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n vault exec -i \
  platform-vault-uniplus-standalone-0 -- sh -c \
  'export VAULT_TOKEN=<root>; vault secrets list | grep transit'
```

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `vaultTransitBootstrap.enabled` | bool | `false` | Liga o chart. Standalone seta `true`; outros environments aguardam `uniplus-infra#45`. |
| `vaultTransitBootstrap.vault.address` | string | `""` | URL absoluta do Vault local. **Sem default utilizável** — environment DEVE sobrescrever. |
| `vaultTransitBootstrap.transit.path` | string | `transit` | Mount path do engine Transit. |
| `vaultTransitBootstrap.key.name` | string | `uniplus-idempotency-aesgcm` | Nome da key Transit. |
| `vaultTransitBootstrap.key.type` | string | `aes256-gcm96` | Algoritmo. |
| `vaultTransitBootstrap.key.deletionAllowed` | bool | `false` | Permitir `vault delete transit/keys/<name>`. |
| `vaultTransitBootstrap.key.exportable` | bool | `false` | Permitir export do material da key. |
| `vaultTransitBootstrap.key.allowPlaintextBackup` | bool | `false` | Snapshot inclui plaintext. |
| `vaultTransitBootstrap.policy.name` | string | `uniplus-api-transit` | Nome da policy. |
| `vaultTransitBootstrap.role.name` | string | `uniplus-api` | Nome da role K8s auth. |
| `vaultTransitBootstrap.role.boundSa` | string | `uniplus-api` | ServiceAccount autorizada. |
| `vaultTransitBootstrap.role.boundNs` | string | `uniplus` | Namespace da ServiceAccount. |
| `vaultTransitBootstrap.role.ttl` | string | `1h` | TTL do token Vault emitido. |
| `vaultTransitBootstrap.externalSecret.secretStoreName` | string | `vault-default` | ClusterSecretStore que materializa o token. |
| `vaultTransitBootstrap.externalSecret.secretStoreKind` | string | `ClusterSecretStore` | `ClusterSecretStore` ou `SecretStore`. |
| `vaultTransitBootstrap.externalSecret.vaultPath` | string | `standalone/vault/root` | Path KV v2 relativo ao mount `secret`. |
| `vaultTransitBootstrap.externalSecret.tokenKey` | string | `token` | Campo na KV que contém o token. |
| `vaultTransitBootstrap.externalSecret.refreshInterval` | string | `1h` | Refresh da Secret materializada. |
| `vaultTransitBootstrap.image.repository` | string | `hashicorp/vault` | Imagem com `vault` CLI. |
| `vaultTransitBootstrap.image.tag` | string | `1.21.2` | Versão alinhada ao Vault server. |
| `vaultTransitBootstrap.networkPolicy.enabled` | bool | `true` | Restringe egress do Job. |
| `vaultTransitBootstrap.networkPolicy.vaultNamespace` | string | `vault` | Destino permitido. |
| `vaultTransitBootstrap.networkPolicy.vaultPort` | int | `8200` | Porta API do Vault. |
| `vaultTransitBootstrap.networkPolicy.kubeDnsCidrs` | list | `[10.43.0.0/16]` | CIDRs para DNS. |

## Pré-requisitos

- Vault local inicializado e unsealed.
- `kubernetes` auth method habilitado no Vault.
- ClusterSecretStore `vault-default` reconciliando (External Secrets Operator).
- ServiceAccount `uniplus-api` no namespace `uniplus` existe (criada pelos
  charts da API).

## Permissões da policy emitida

```hcl
path "transit/encrypt/uniplus-idempotency-aesgcm" {
  capabilities = ["update"]
}

path "transit/decrypt/uniplus-idempotency-aesgcm" {
  capabilities = ["update"]
}
```

Sem `read`, `rewrap`, `datakey`, `export`, `backup` ou rotate. Administração
da key (rotate, datakey config) fica fora do escopo runtime da `uniplus-api`.
