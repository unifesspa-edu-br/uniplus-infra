# OpenTofu — standalone-compact OCI

Lab Uni+ em **`sa-saopaulo-1` (GRU)** sobre **`VM.Standard.A1.Flex` Always Free**
(ARM Ampere), topologia compacta para custo zero recorrente.

## Diferenças vs `provisioning/oci/standalone/`

| Atributo | standalone (legado) | standalone-compact |
|---|---|---|
| Região | `sa-saopaulo-1` | `sa-saopaulo-1` (igual, home region) |
| Shape | `VM.Standard.E5.Flex` AMD x86 | **`VM.Standard.A1.Flex` ARM Ampere** |
| Profile | poc=3 OCPU/16 GB total | **4 OCPU / 24 GB total** (limite Always Free A1) |
| Imagem | Ubuntu 24.04 x86_64 | **Ubuntu 24.04 aarch64** |
| VCN CIDR | 10.0.0.0/16 | **10.2.0.0/16** |
| Subnets | public + private | **2 públicas** (split por SL, sem NAT) |
| NAT Gateway | sim (~$33/mês) | **NÃO** (eliminado) |
| Block volumes | 4 distintos, 550 GB total | **1 volume 100 GB no data-host** |
| Tag `uniplus_environment` | `standalone` | `standalone-compact` |
| DNS subdomínio | `*.standalone.portaluni.com.br` | `*.compact.portaluni.com.br` |
| **Custo mensal estimado** | ~$108/mês (era ativo) ou ~$17/mês (dormante) | **~$0/mês** |

## Por que custo zero

Always Free OCI **em home region** cobre TUDO:

- **A1 Compute**: 3000 OCPU-hours/mês + 18000 GB-hours/mês. 4 OCPU × 730h = 2920 ✓, 24 GB × 730h = 17520 ✓
- **Block Volume**: 200 GB total combinando boot + block. 2 × 47 boot + 100 block = 194 GB ✓
- **Internet Gateway**: free
- **Reserved Public IP**: free quando attached a VM running
- **Egress 10 TB/mês**: free
- **KMS Vault**: 20 keys + 10k crypto ops/mês free
- **DNS**: PAYG ~$0.04/mês (10 RRSets, ínfimo)
- **NAT Gateway**: removido (eliminação do item mais caro do lab anterior)

## Topologia

```
                ┌─── Internet ────┐
                       │
                ┌──────▼──────┐
                │     IGW     │  Always Free
                └──────┬──────┘
                       │
              ┌────────▼─────────────────────┐
              │ VCN  10.2.0.0/16              │
              │                               │
              │  subnet k8s 10.2.1.0/24       │
              │   ┌─────────────────────┐     │
              │   │ k8s-host (Reserved)│     │  HTTP/HTTPS/SSH público
              │   │ A1 2 OCPU / 12 GB  │     │
              │   └────────┬───────────┘     │
              │            │ servicos        │
              │            ▼ via VCN         │
              │  subnet data 10.2.2.0/24      │
              │   ┌─────────────────────┐     │
              │   │ data-host (efêmero)│     │  Postgres/Kafka/MinIO/Vault/Redis
              │   │ A1 2 OCPU / 12 GB  │     │  SL bloqueia ingress externo
              │   │ + 100 GB block     │     │
              │   └─────────────────────┘     │
              └───────────────────────────────┘
```

## Pré-requisitos

- OpenTofu ≥ 1.6 (testado com 1.11.6; ≥ 1.9 para preservação Reserved IP)
- Tenancy unifesspa-edu-br em modo **PAYG**
- Always Free A1 disponível em GRU no momento do apply (capacidade dinâmica)
- `oci` CLI configurado, permissão `manage` em `instance-family` + `volume-family`

## Setup

```bash
cd provisioning/oci/standalone-compact

# 1. Copiar tfvars + preencher OCIDs/SSH key/image
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Descobrir image OCID
oci compute image list --region sa-saopaulo-1 \
  --compartment-id "$TENANCY" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version 24.04 \
  --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output

# 3. Init + validate + plan
tofu init
tofu validate
tofu plan -out=plan.bin

# 4. Apply
tofu apply plan.bin
```

## Bootstrap (após apply)

⚠️ **Bloqueado por Story [#380](https://github.com/unifesspa-edu-br/uniplus-infra/issues/380)** (refatoração do discovery por display_name em vez de tamanho).

Topologia compacta tem 1 disco em vez de 4 distintos. O `bootstrap-standalone.sh` atual identifica papéis por tamanho (45-55 → vault, 95-105 → kafka, 190-210 → postgres+minio) e falharia.

Plano: refator do bootstrap usa instance principal + OCI metadata API para resolver `display_name` → role (futuro `att-data-host-uniplus-data` em vez de matching por size).

Pós-refator, o particionamento LVM no data-host:

```bash
# Bootstrap cria PV → VG → LVs
sudo pvcreate /dev/oracleoci/oraclevdb
sudo vgcreate uniplus-vg /dev/oracleoci/oraclevdb

# Distribuição sugerida (100 GB total):
sudo lvcreate -L 30G -n lv-postgres uniplus-vg
sudo lvcreate -L 20G -n lv-kafka    uniplus-vg
sudo lvcreate -L 40G -n lv-minio    uniplus-vg
sudo lvcreate -L 10G -n lv-vault    uniplus-vg

# Cada LV recebe ext4 + mount em /var/lib/<service>
```

## Operações típicas

```bash
tofu show
tofu output

# Aumentar block (in-place online)
$EDITOR terraform.tfvars  # volume_size_gbs = 150
tofu apply
ssh -J ubuntu@<k8s-public-ip> ubuntu@<data-private-ip> "sudo lvextend -L +50G /dev/uniplus-vg/lv-minio && sudo resize2fs /dev/uniplus-vg/lv-minio"

# IMPORTANTE: 200 GB total é o teto do Always Free. Acima disso paga
# ~$0.0255/GB-mês PAYG. Reduzir abaixo de 50 GB NÃO é possível.
```

### Recriar do zero PRESERVANDO o Reserved IP

Idêntico ao runbook do `iad-arm/`. Sequência **ingênua** `tofu destroy && tofu apply` rotaciona o IP. Use uma das duas:

**Opção A (preferida) — `-exclude` no destroy** (OpenTofu ≥ 1.9):

```bash
tofu destroy -exclude=oci_core_public_ip.k8s_host
tofu apply
```

**Opção B — `state rm` + `import` antes do apply** (compat < 1.9):

```bash
OLD_IP_OCID=$(tofu output -raw k8s_host_reserved_ip_ocid)
tofu state rm oci_core_public_ip.k8s_host
tofu destroy
tofu import oci_core_public_ip.k8s_host "$OLD_IP_OCID"   # antes do apply!
tofu apply
```

## Bridge para os charts Helm

Mesma estratégia do `standalone/`. Quando o bootstrap (#380) estiver pronto, criar `environments/standalone-compact/values.yaml` com IPs/FQDN do compact, e estender `scripts/sync-tofu-outputs.sh` para reconhecer este módulo.

## State

State **local** por padrão (`terraform.tfstate` ignorado pelo `.gitignore`). Mesma decisão de `standalone/`. Backend remoto fica para refinamento futuro.

## Cleanup do standalone antigo

Quando este compact estiver bootstrap concluído e validado:

```bash
cd ../standalone
tofu destroy
```

Libera os 550 GB de block volumes antigos (atualmente cobrando ~$14/mês mesmo com VMs OFF). Após destroy, o compact fica 100% Always Free a $0/mês.

## Próximos passos

1. Smoke apply deste módulo (este PR)
2. Refator bootstrap-standalone.sh ([#380](https://github.com/unifesspa-edu-br/uniplus-infra/issues/380)) — discovery por display_name
3. Bootstrap: k3s no k8s-host + LVM no data-host + Helm deploy platform/apps
4. Validação smoke (SSH, HTTP, Helm health)
5. Cutover DNS para domínio canônico + `tofu destroy` em `standalone/`
