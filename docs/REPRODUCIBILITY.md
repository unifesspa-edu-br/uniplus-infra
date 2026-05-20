# Reprodutibilidade da infraestrutura

Como garantir que o `standalone-compact` pode ser recriado do zero em outro
ambiente (ou após perda total) com resultado previsível. Documento operacional —
manter sincronizado com `provisioning/oci/standalone-compact/` e
`scripts/bootstrap-standalone.sh`.

## Por que isso importa

O ambiente atual foi provisionado **uma vez** e depois ajustado ao vivo (DNS
cutover via OCI CLI, Vault inicializado à mão, secrets sincronizados
manualmente). Validação estática (`make validate`, `tofu validate`) prova que o
código tem sintaxe e schema corretos, mas **não** prova que ele sobe um ambiente
funcional do zero. A única prova real é destruir e recriar.

## Camadas de garantia

| Camada | Comando | Prova |
|---|---|---|
| Estática | `make validate` + job `tofu-validate` no CI | sintaxe HCL/YAML, schema dos charts, render Helm, `tofu fmt`/`validate` |
| Drift | `tofu -chdir=provisioning/oci/standalone-compact plan` | código declara == infra viva (ideal: `No changes`) |
| Idempotência | reexecutar `bootstrap-standalone.sh` numa VM já provisionada | re-run não quebra nem duplica |
| **Recreate drill** | `tofu apply` + bootstrap + smokes num ambiente efêmero | reprodutibilidade ponta a ponta |

Só o **recreate drill** prova reprodutibilidade. As demais camadas são
pré-requisitos baratos que pegam regressões antes do drill.

## O que é codificado vs manual

| Etapa | Estado | Onde |
|---|---|---|
| VMs, rede, DNS, block volume | ✅ codificado | `provisioning/oci/standalone-compact/*.tf` |
| K3s + Helm + ArgoCD + LVM + data services | ⚠️ codificado, execução manual | `scripts/bootstrap-standalone.sh` rodado via SSH (sem cloud-init ainda — issue #387) |
| Charts de app e plataforma | ✅ codificado (GitOps) | `apps/`, `platform/`, `environments/standalone-compact/` |
| **State do Tofu** | ⚠️ **local** (laptop) | `terraform.tfstate` — gitignored; sem backend remoto. Ver issue de state remoto |
| **Vault init/unseal** | ❌ manual | Shamir 5/3 à mão; unseal keys em `/home/ubuntu/vault-init.json` |
| **Seed de secrets** | ❌ manual | ~30 secrets populados via `vault kv put`; client_secrets OIDC sincronizados à mão com o Keycloak |
| **Cutover de DNS** | ⚠️ semi | `dns.tf` cobre os records; o reaponte inicial do A record foi via OCI CLI |

Enquanto Vault e seed de secrets não forem codificados, **o recreate sempre
exige intervenção humana** — o drill serve tanto para validar quanto para manter
este checklist honesto.

## Pré-requisitos do drill

- Credenciais OCI (`~/.oci/config`) com permissão no compartment de teste
- `tofu`, `kubectl`, `helm`, `oci` CLI, `ssh`
- Um subdomínio livre (ex.: `drill.portaluni.com.br`) **diferente** do
  `standalone.portaluni.com.br` produtivo, para não colidir com o ambiente vivo
- `terraform.tfvars` com `compartment_ocid` de teste e a chave SSH

> **Importante:** rodar o drill **sempre** com state e subdomínio próprios.
> Nunca apontar o drill para o state ou o DNS do ambiente vivo.

## Procedimento de recreate drill

```bash
cd provisioning/oci/standalone-compact

# 1. Init + plan (revisar o plano antes de aplicar)
tofu init
tofu plan -out=drill.tfplan

# 2. Apply — cria as 2 VMs, rede, DNS, block volume
tofu apply drill.tfplan

# 3. Bootstrap — manual via SSH (sem cloud-init ainda — issue #387). Copiar o
#    script para a VM (scp/git clone) e rodar:
ssh ubuntu@<k8s-host-ip> 'sudo ./bootstrap-standalone.sh --role=standalone-k8s'
ssh -J ubuntu@<k8s-host-ip> ubuntu@10.2.2.11 \
  'sudo ./bootstrap-standalone.sh --role=standalone-data'

# 4. Passos MANUAIS (ainda não codificados — ver checklist abaixo)
#    - inicializar e unsealar o Vault
#    - popular os secrets
#    - registrar o cluster no ArgoCD

# 5. Validar
./scripts/validate-standalone.sh
./scripts/validate-cluster.sh
./scripts/smoke-dashboards.sh
./scripts/smoke-encryption-e2e.sh
./scripts/smoke-metrics-pipeline.sh

# 6. Validar E2E pela UI (Playwright ou manual): login SSO, dashboards,
#    criação de edital ponta a ponta

# 7. Destruir o ambiente de drill
tofu destroy
```

## Checklist dos passos manuais (executar entre 4 e 5)

- [ ] **Vault init:** `vault operator init -key-shares=5 -key-threshold=3` →
      guardar as 5 unseal keys + root token com segurança
- [ ] **Vault unseal:** `vault operator unseal` × 3 (quórum)
- [ ] **KV v2 + auth Kubernetes + role/policy** do External Secrets
- [ ] **Seed de secrets** em `secret/standalone/*` (Postgres, Kafka, MinIO,
      Redis, Keycloak admin, JWT signing)
- [ ] **Sincronizar client_secrets OIDC** Keycloak ↔ Vault
      (grafana, apicurio-registry, kafka-ui, uniplus-api-*)
- [ ] **Registrar cluster no ArgoCD** com os labels corretos:
      ```bash
      argocd cluster add <kube-context> \
        --name uniplus-standalone-compact \
        --label uniplus.io/managed=true \
        --label environment=standalone-compact
      ```
- [ ] **Forçar refresh** dos ExternalSecrets e aguardar os pods subirem

## Critérios de sucesso

- `tofu apply` conclui sem erro e `tofu plan` subsequente retorna `No changes`
- `validate-standalone.sh` reporta `X OK, 0 ERROS`
- Os 3 smokes passam
- Login SSO funciona em Grafana / AKHQ / Apicurio (ver
  `docs/RUNBOOKS.md`)
- Fluxo E2E (criar edital pela UI) completa
- `tofu destroy` remove tudo sem recursos órfãos

## Gaps rastreados

Cada passo manual acima é débito de reprodutibilidade com issue própria:

- **#383** — State remoto (OCI Object Storage + lock); sem isso `tofu plan` só roda no laptop
- **#384** — Vault OCI KMS auto-unseal; remove o Shamir manual
- **#385** — Seed de secrets codificado; remove o `vault kv put` manual e a dessincronização Keycloak ↔ Vault
- **#386** — Recreate drill agendado no CI; automatiza esta página (bloqueado por #383/#384/#385)

Quando os quatro fecharem, o recreate drill roda sem intervenção humana e
esta página passa a descrever um processo totalmente automatizado.
