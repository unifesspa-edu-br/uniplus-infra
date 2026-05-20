# OpenTofu — standalone-compact OCI

Provisiona o ambiente operacional do Uni+ em **`sa-saopaulo-1` (GRU, home region)**
sobre **`VM.Standard.E4.Flex` AMD x86_64** (PAYG), topologia compacta de 2 VMs.

## Perfil

| Atributo | Valor |
|---|---|
| Região | `sa-saopaulo-1` (home region — preserva Block Volume Always Free) |
| Shape | `VM.Standard.E4.Flex` AMD x86_64 (PAYG) |
| k8s-host | 2 OCPU / 8 GB (escalável a 12 GB via live-resize) + boot 47 GB + Reserved Public IP |
| data-host | 1 OCPU / 4 GB + boot 47 GB + 1 block 100 GB · IP privado fixo `10.2.2.11` |
| VCN | `10.2.0.0/16` — subnet k8s `10.2.1.0/24`, subnet data `10.2.2.0/24` |
| NAT Gateway | não (subnets públicas + Security List restritiva no data-host) |
| DNS | `*.standalone.portaluni.com.br` |
| **Custo mensal** | **~$9,60 PAYG** (3 OCPU + 12 GB) + $0 storage (boot+block ≤ 200 GB Always Free) |

> **Por que AMD e não A1 Always Free?** A1 Always Free não está disponível em GRU
> para esta tenancy, e A1 PAYG em região não-home perde o benefício free. O pivot
> para E4.Flex AMD em GRU (2026-05-19) mantém o Block Volume Always Free e fica em
> ~$9,60/mês de compute. Histórico em `CHANGELOG.md`.

## Topologia

```
                ┌─── Internet ────┐
                       │
                ┌──────▼──────┐
                │     IGW     │
                └──────┬──────┘
                       │
              ┌────────▼─────────────────────┐
              │ VCN  10.2.0.0/16              │
              │                               │
              │  subnet k8s 10.2.1.0/24       │
              │   ┌──────────────────────┐    │
              │   │ k8s-host (Reserved IP)│   │  HTTP/HTTPS/SSH público
              │   │ E4.Flex 2 OCPU / 8 GB │   │  K3s + Helm + ArgoCD
              │   └────────┬─────────────┘    │
              │            │ serviços via VCN │
              │            ▼                  │
              │  subnet data 10.2.2.0/24      │
              │   ┌──────────────────────┐    │
              │   │ data-host (10.2.2.11) │   │  Postgres/Kafka/MinIO/Vault/Redis
              │   │ E4.Flex 1 OCPU / 4 GB │   │  SL bloqueia ingress externo
              │   │ + 100 GB block (LVM)  │   │
              │   └──────────────────────┘    │
              └───────────────────────────────┘
```

## Pré-requisitos

- OpenTofu ≥ 1.6 (≥ 1.9 recomendado para `-exclude` na preservação do Reserved IP)
- Tenancy unifesspa-edu-br em modo PAYG
- `oci` CLI configurado, permissão `manage` em `instance-family` + `volume-family`

## Setup

```bash
cd provisioning/oci/standalone-compact

# 1. Copiar tfvars + preencher OCIDs/SSH key/image
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Descobrir image OCID (Ubuntu 24.04 LTS x86_64, compatível com E4.Flex)
oci compute image list --region sa-saopaulo-1 \
  --compartment-id "$TENANCY" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version 24.04 \
  --shape VM.Standard.E4.Flex \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output

# 3. Init + validate + plan + apply
tofu init
tofu validate
tofu plan -out=plan.tfplan
tofu apply plan.tfplan
```

Após o apply, rode `scripts/bootstrap-standalone.sh` **manualmente via SSH** em
cada VM (K3s + Helm + ArgoCD no k8s-host; LVM + data services no data-host). O
`compute.tf` ainda não injeta `user_data`/cloud-init — automatizar isso é a
issue #387.

## Operações típicas

```bash
tofu show
tofu output

# Aumentar block (in-place online)
$EDITOR terraform.tfvars  # volume_size_gbs = 150
tofu apply
ssh -J ubuntu@<k8s-public-ip> ubuntu@10.2.2.11 \
  "sudo lvextend -L +50G /dev/uniplus-vg/lv-minio && sudo xfs_growfs /var/lib/uniplus/minio"
```

> O block + boot somam 194 GB hoje (≤ 200 GB Always Free). Acima de 200 GB
> entra em PAYG (~$0,0255/GB-mês). Reduzir abaixo de 50 GB não é suportado pela OCI.

### Recriar do zero PRESERVANDO o Reserved IP

`tofu destroy && tofu apply` ingênuo rotaciona o IP público (e quebra DNS, callback
gov.br, certs Let's Encrypt, `KC_HOSTNAME`). Use uma das duas:

**Opção A (preferida) — `-exclude` no destroy** (OpenTofu ≥ 1.9):

```bash
tofu destroy -exclude=oci_core_public_ip.k8s_host
tofu apply
```

**Opção B — `state rm` + `import`** (compat < 1.9):

```bash
OLD_IP_OCID=$(tofu output -raw k8s_host_reserved_ip_ocid)
tofu state rm oci_core_public_ip.k8s_host
tofu destroy
tofu import oci_core_public_ip.k8s_host "$OLD_IP_OCID"   # antes do apply!
tofu apply
```

## Bridge para os charts Helm

`scripts/sync-tofu-outputs.sh` compara os outputs do Tofu com
`environments/standalone-compact/values.yaml` (`--diff`) e pode materializar um
ConfigMap (`--apply-configmap`). Ver o cabeçalho do script.

## State

State **local** por padrão (`terraform.tfstate` ignorado pelo `.gitignore`).
Migração para backend remoto (OCI Object Storage + lock) é rastreada na issue #383
— sem ela, `tofu plan` só roda na máquina que detém o state.

## Reprodutibilidade

O procedimento completo de recriação do ambiente (recreate drill) e o checklist
dos passos manuais (Vault init/unseal, seed de secrets, registro no ArgoCD) estão
em `docs/REPRODUCIBILITY.md`.
