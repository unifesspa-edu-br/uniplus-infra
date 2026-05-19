# OpenTofu — iad-arm OCI

Provisionamento OpenTofu do lab Uni+ em **`us-ashburn-1` (IAD)** sobre
**`VM.Standard.A1.Flex`** (ARM Ampere). Esqueleto da Story
[#323](https://github.com/unifesspa-edu-br/uniplus-infra/issues/323) (parte do
Epic [#317](https://github.com/unifesspa-edu-br/uniplus-infra/issues/317) —
migração do lab de GRU/E5 para IAD/A1 antes do trial OCI expirar em
2026-06-03).

Cobertura: VCN (10.1.0.0/16), 2 subnets, IGW, NAT GW, 2 route tables, 2
security lists, 2 VMs A1.Flex (k8s-host + data-host), 4 block volumes
(4×50 GB = 200 GB total — 50 GB é o mínimo da OCI), Reserved Public IP,
11 DNS records sob `iad-arm.portaluni.com.br`, KMS Vault + Master Encryption
Key, Dynamic Group, IAM Policy.

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
| Block volumes | 550 GB total (postgres 200 + kafka 100 + minio 200 + vault 50) | 200 GB total (4×50, mínimo OCI) — Always Free Block Volume é só na home region (GRU); em IAD os volumes são PAYG ~$5/mês |
| Tag `uniplus_environment` | `standalone` | `iad-arm` |
| DNS subdomínio | `*.standalone.portaluni.com.br` | `*.iad-arm.portaluni.com.br` |
| Custo (PAYG estimado) | ~$108/mês | **~$80/mês** (detalhamento abaixo) |

### Detalhamento do custo IAD

| Recurso | Custo/mês | Observação |
|---|---|---|
| Compute A1 (3 OCPU / 16 GB) | **~$39,40** | Oracle docs: "You must create the Always Free compute instances in your home region". Home = GRU, então A1 em IAD vai para PAYG (3 OCPU × $0,01/h + 16 GB × $0,0015/h ≈ $39,40/mês). Ver gate de validação abaixo |
| Block volumes (4×50 GB = 200 GB, VPU 0) | **~$5,10** | Always Free Block Volume também é home-region-only — IAD é PAYG $0,0255/GB-mês |
| Boot volumes (2× ~47 GB ≈ 94 GB) | **~$2,40** | Mesma regra dos block volumes |
| NAT Gateway | **~$33** | Cobrado mesmo em Always Free; eliminação é follow-up |
| **Total** | **~$79-80/mês** | Economia vs GRU (~$108): ~$28/mês (~26%) |

> **Premissa que mudou:** O Epic #317 foi escrito assumindo `~$0-3/mês em IAD`
> com base na interpretação de que Always Free A1 valeria cross-region.
> Re-leitura da [doc oficial Oracle](https://docs.oracle.com/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
> mostra que o texto `"In regions with multiple availability domains: You can
> create OCI Ampere A1 Compute instances in any availability domain"`
> qualifica a flexibilidade **dentro de uma única região** (a home region),
> não cross-region. A regra geral `"must create in home region"` se aplica
> a A1 e a AMD Micro. Story #366 (ajuste do Budget OCI) mantém USD 50/mês
> em vez de reduzir para USD 10-25 — a frente do NAT GW elimination ganha
> prioridade para recuperar economia.

### Gate de validação operacional (Story #319/T1.1.3)

Validação parcial executada em 2026-05-19 02:03-02:11 UTC via OCI CLI:

| Etapa | Resultado |
|---|---|
| `oci iam region-subscription list` | IAD já READY (subscrita) |
| `oci compute image list --shape VM.Standard.A1.Flex` em IAD | imagem Ubuntu 24.04 aarch64 encontrada |
| `oci compute instance launch` 1 OCPU / 1 GB em `mixQ:US-ASHBURN-AD-1` | ✓ **API aceitou sem rejeitar por home region** |
| Instance lifecycle até `RUNNING` | ✓ ~30s, normal |
| `oci usage-api request-summarized-usages` | inconclusivo — Usage API tem delay ~1h, dados não disponíveis no momento do teste |

**Achado parcial:** A doc Oracle diz literalmente `"must create in home region"` mas o API **não bloqueia** a criação em região não-home. Resta confirmar via billing se A1 em IAD é classificado como Always Free ou PAYG.

**Próximo passo (Story #319/T1.1.3 ou follow-up):** repetir o teste deixando a instância rodar por ≥1h e re-query `oci usage-api` filtrando por `region=us-ashburn-1` e `service=Compute`:
- Se aparecer com `computed-amount > 0` → PAYG confirmado, README ~$80/mês mantido
- Se aparecer com `computed-amount = 0` ou ausente → Always Free aplica cross-region, revisar README para ~$42/mês e atualizar Epic #317

PAYG já ativo na tenancy desde a Feature #43, então qualquer cobrança aparece no billing imediatamente após o flush (~1-2h).

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

# IMPORTANTE: block volumes em IAD são PAYG (Always Free é home-region-only,
# = GRU para esta tenancy). Custo VPU 0: ~$0.0255/GB-mês. Cada 50 GB extras
# = ~$1.28/mês — verificar Budget OCI via Console antes de aumentar.
# Reduzir abaixo do mínimo de 50 GB NÃO é possível (CreateVolume rejeita).

# Mudar perfil de capacidade
# poc_arm (default): 3 OCPU / 16 GB → ~$39/mês compute em IAD (PAYG, ver
#                    cost table no topo do README)
# hml_arm:           6 OCPU / 40 GB → ~$86/mês compute em IAD
#                    (6 × $0.01/h + 40 × $0.0015/h ≈ $86.40/mês), total
#                    com storage e NAT ~$127/mês — JÁ ULTRAPASSA o GRU
#                    atual; só fazer sentido pós elimination do NAT GW.
$EDITOR terraform.tfvars   # profile = "hml_arm"
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
