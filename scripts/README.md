# Scripts

Scripts de operação do ambiente `standalone-compact` (1 cluster K3s + 1 data-host externo em OCI GRU).

| Script | Função |
|--------|--------|
| `bootstrap-standalone.sh` | Provisiona o ambiente standalone OCI (roles `standalone-k8s` e `standalone-data`); executado manualmente via SSH após o `tofu apply` |
| `validate-standalone.sh` | Valida saúde do ambiente (k8s-host + data-host) — usado após o bootstrap |
| `validate-cluster.sh` | Smoke pós-bootstrap focado no K3s (Pods Running, ArgoCD Synced, IngressRoute respondendo) |
| `resize-standalone-oci.sh` | Hot-resize dos shapes (OCPU + RAM) das 2 VMs OCI; perfis pré-definidos para POC/HML |
| `sync-tofu-outputs.sh` | Bridge entre `tofu output` (`provisioning/oci/standalone-compact/`) e os charts Helm. Modos: `--diff`, `--apply-configmap`, `--json` |
| `smoke-dashboards.sh` | Smoke dos dashboards Grafana provisionados |
| `smoke-encryption-e2e.sh` | Smoke do pipeline Vault → ExternalSecrets → Pod |
| `smoke-metrics-pipeline.sh` | Smoke do pipeline OTel → Prometheus → Grafana |
| `validate-rfc1123.py` | Valida nomes RFC 1123 em todos os charts (consumido pelo CI) |

## Standalone OCI (dois hosts Ubuntu)

Topologia: 1 `k8s-host` (K3s + Helm + ArgoCD) + 1 `data-host` (Docker + volumes LVM para Postgres, Kafka, MinIO, Vault e Redis).

Após o `tofu apply` em `provisioning/oci/standalone-compact/`, o
`bootstrap-standalone.sh` é executado **manualmente via SSH** em cada VM (o
`compute.tf` ainda não injeta `user_data`/cloud-init — automatizar isso é a
issue #387). Copie o script para a VM (ou faça `git clone` do repo) e rode:

```bash
# No k8s-host — K3s + Helm + ArgoCD
./scripts/bootstrap-standalone.sh --role=standalone-k8s

# No data-host — Docker + LVM + mount points + data services
./scripts/bootstrap-standalone.sh --role=standalone-data

# Dry-run (mostra o que seria feito, sem executar)
./scripts/bootstrap-standalone.sh --role=standalone-k8s --dry-run
./scripts/bootstrap-standalone.sh --role=standalone-data --dry-run

# Flags disponíveis
#   --skip-k3s        Pula instalação do K3s (standalone-k8s)
#   --skip-docker     Pula instalação do Docker (standalone-data)
#   --skip-services   Pula bring-up dos services (standalone-data, debug)
```

O bootstrap do data-host descobre os block volumes OCI automaticamente. Para o standalone-compact a topologia é 1 disco LVM-particionado (4 LVs). Verificar com `lsblk` antes de rodar.

### Validação

```bash
# Smoke completo (valida os dois hosts a partir do k8s-host)
./scripts/validate-standalone.sh

# Sobrepor IP do data-host (padrão: 10.2.2.11)
DATA_HOST_IP=10.2.2.11 ./scripts/validate-standalone.sh
```

Saída esperada: **`X OK, 0 ERROS, Y AVISOS`**. Avisos são esperados enquanto serviços ainda estão subindo.

## Histórico

Até 2026-05-19 o diretório também trazia `bootstrap-lab.sh` e `teardown-lab.sh` para um laboratório multi-DC (Ryzen 9950X + i7) que nunca foi provisionado. Os scripts foram removidos junto com `environments/lab-*`, `environments/prod-*` e `environments/standalone/` (ver `CHANGELOG.md`).
