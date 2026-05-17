# OpenTofu — iad-arm OCI

Provisionamento OpenTofu do lab Uni+ em **`us-ashburn-1` (IAD)** sobre
**`VM.Standard.A1.Flex`** (ARM Ampere). Esqueleto da Story
[#323](https://github.com/unifesspa-edu-br/uniplus-infra/issues/323) (parte do
Epic [#317](https://github.com/unifesspa-edu-br/uniplus-infra/issues/317) —
migração do lab de GRU/E5 para IAD/A1 antes do trial OCI expirar em
2026-06-03).

Cobertura: VCN (10.1.0.0/16), 2 subnets, IGW, NAT GW, 2 route tables, 2
security lists, 2 VMs A1.Flex (k8s-host + data-host), 4 block volumes ≤200 GB
total, Reserved Public IP, 11 DNS records sob `iad-arm.portaluni.com.br`,
KMS Vault + Master Encryption Key, Dynamic Group, IAM Policy.

> **Paralelo a `provisioning/oci/standalone/`:** este módulo NÃO substitui o
> lab GRU enquanto a migração não completar. Os dois coexistem durante a
> janela: `standalone.portaluni.com.br` aponta para GRU, `iad-arm.portaluni.com.br`
> aponta para IAD. O cutover final (Story
> [#359](https://github.com/unifesspa-edu-br/uniplus-infra/issues/359))
> reaponta o domínio canônico e destrói o lab GRU.

## Diferenças vs `provisioning/oci/standalone/`

| Atributo | standalone (GRU) | iad-arm (IAD) |
|---|---|---|
| Região | `sa-saopaulo-1` | `us-ashburn-1` |
| Shape | `VM.Standard.E5.Flex` (AMD x86) | `VM.Standard.A1.Flex` (ARM Ampere) |
| Imagem | Ubuntu 24.04 LTS x86_64 | Ubuntu 24.04 LTS **aarch64** |
| Profile default | `poc` (3 OCPU / 16 GB E5) | `poc_arm` (3 OCPU / 16 GB A1) |
| VCN CIDR | 10.0.0.0/16 | 10.1.0.0/16 |
| Block volumes | 550 GB total (postgres 200 + kafka 100 + minio 200 + vault 50) | 150 GB total (postgres 15 + kafka 15 + minio 110 + vault 10) — prioriza MinIO para logs; 50 GB de folga sob o limite Always Free de 200 GB |
| Tag `uniplus_environment` | `standalone` | `iad-arm` |
| DNS subdomínio | `*.standalone.portaluni.com.br` | `*.iad-arm.portaluni.com.br` |
| Custo (PAYG estimado) | ~$108/mês | ~$0-3/mês (compute + storage Always Free) |

## Pré-requisitos

- OpenTofu ≥ 1.6 (testado com 1.11.6)
- Tenancy unifesspa-edu-br em modo **PAYG** (Always Free puro não permite
  subscrição de região adicional — bloqueio confirmado em `TenantCapacityExceeded`)
- Região `us-ashburn-1` assinada na tenancy
  ([Task #320](https://github.com/unifesspa-edu-br/uniplus-infra/issues/320))
- `oci` CLI configurado com permissão `manage` em `instance-family` +
  `volume-family` no compartment alvo

## Placeholders pendentes (REPLACE_AFTER_T1_1_2)

Os defaults de `variables.tf` contêm 2 strings literais `REPLACE_AFTER_T1_1_2`
em `availability_domain` e `image_ocid` que precisam ser substituídas após
[Task #321](https://github.com/unifesspa-edu-br/uniplus-infra/issues/321):

```bash
# 1. Listar AD em IAD (após subscrição estar READY)
oci iam availability-domain list --region us-ashburn-1 \
  --compartment-id "$TENANCY" \
  --query 'data[0].name' --raw-output

# 2. Listar imagem Ubuntu 24.04 LTS aarch64 mais recente para A1.Flex
oci compute image list --region us-ashburn-1 \
  --compartment-id "$TENANCY" \
  --operating-system "Canonical Ubuntu" \
  --operating-system-version 24.04 \
  --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC \
  --query 'data[0].id' --raw-output
```

Os 2 valores entram em `terraform.tfvars` (não em `variables.tf` — defaults
ficam com placeholder no git para sinalizar pendência).

## Setup inicial

```bash
cd provisioning/oci/iad-arm

# 1. Copiar tfvars de exemplo e preencher OCIDs/SSH key/AD/image
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Inicializar provider + plugins
tofu init

# 3. Validar sintaxe (rodável SEM access OCI)
tofu validate

# 4. Plan (precisa de OCI access para resolver data sources como dns_zones)
tofu plan -out=plan.bin

# 5. Apply (Story #329)
tofu apply plan.bin
```

> **Sem importação:** diferente do `standalone/`, este módulo é apply
> "from zero" — não há recursos vivos em IAD para importar.

## Operações típicas

```bash
# Ver estado atual + outputs
tofu show
tofu output

# Aumentar tamanho dos blocks (in-place, online, sem reboot)
$EDITOR terraform.tfvars   # volume_sizes_gbs.postgres = 120
tofu apply
# Pós-apply, estender o FS dentro da VM:
ssh ubuntu@<k8s-host-ip> "ssh ubuntu@10.1.2.x 'sudo growpart /dev/sdb 1 && sudo resize2fs /dev/sdb1'"

# IMPORTANTE: aumentar volumes além de 200 GB total passa a cobrar
# ~$0.0085/GB-extra/mês — verificar Budget USD 50/mês via OCI Console.

# Mudar perfil de capacidade
$EDITOR terraform.tfvars   # profile = "hml_arm"  (cobra ~$25/mês de A1 paga)
tofu apply

# Recriar do zero (CUIDADO — destrutivo total: destroi VMs, volumes, VCN
# E o Reserved Public IP). Apos `tofu apply` subsequente, o RESERVED IP
# alocado sera DIFERENTE — DNS records, callback URLs do gov.br,
# Let's Encrypt certs e KC_HOSTNAME precisam ser reconfigurados.
#
# Para preservar o IP entre destroy/apply, ha duas opcoes:
#   1. Adicionar `lifecycle { prevent_destroy = true }` ao
#      `oci_core_public_ip.k8s_host` (forca destroy parcial — exclui o IP)
#   2. `tofu state rm oci_core_public_ip.k8s_host` antes do destroy +
#      `tofu import oci_core_public_ip.k8s_host <ocid>` apos o apply
# Em qualquer caso, o IP nao volta automaticamente.
tofu destroy
tofu apply
```

## Bridge para os charts Helm

Mesma estratégia documentada em `provisioning/oci/standalone/README.md` —
ao chegar na Story
[#350](https://github.com/unifesspa-edu-br/uniplus-infra/issues/350) (bootstrap
completo IAD), criar `environments/iad-arm/values.yaml` espelhando o
`environments/standalone/values.yaml` com IPs/FQDN do IAD, e estender
`scripts/sync-tofu-outputs.sh` para reconhecer este módulo.

## State

State **local** por padrão (`terraform.tfstate` ignorado pelo `.gitignore`).
Mesma decisão do `standalone/`. Backend remoto fica para refinamento futuro.

## Próximos passos

| Story | Conteúdo |
|---|---|
| [#319](https://github.com/unifesspa-edu-br/uniplus-infra/issues/319) | Assinar IAD + descobrir OCIDs (AD, imagem aarch64) |
| [#329](https://github.com/unifesspa-edu-br/uniplus-infra/issues/329) | `tofu apply` em IAD + validação de smoke |
| [#346](https://github.com/unifesspa-edu-br/uniplus-infra/issues/346) | Adaptar `bootstrap-standalone.sh` para arm64 |
| [#350](https://github.com/unifesspa-edu-br/uniplus-infra/issues/350) | Bootstrap k3s+ArgoCD+Helm em IAD |
| [#354](https://github.com/unifesspa-edu-br/uniplus-infra/issues/354) | Migração de dados GRU → IAD |
| [#359](https://github.com/unifesspa-edu-br/uniplus-infra/issues/359) | Cutover DNS + `tofu destroy` em GRU |
