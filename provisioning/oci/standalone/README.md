# OpenTofu — standalone OCI

Provisionamento OpenTofu do ambiente standalone Uni+ na OCI (sa-saopaulo-1).
Cobertura mínima viável (Stories #52, #54 e #55 da Feature #43): as 2 VMs
E5.Flex e os 4 block volumes do data-host. Recursos de rede (VCN, subnets,
IGW, NSGs) ficam **fora deste recorte** — provisionados manualmente,
importados via referência por OCID. A migração da rede é a Story #53
(`network.tf`).

## Estado atual no OCI

Aplicado em 2026-05-04 (manual via console) + redimensionado em 2026-05-10
para o perfil `poc` via `scripts/resize-standalone-oci.sh`:

| Recurso | Detalhe |
|---|---|
| `uniplus-standalone-k8s-host` | E5.Flex 2 OCPU / 12 GB; subnet pública 10.0.1.0/24; public IP `164.152.53.29` |
| `uniplus-standalone-data-host` | E5.Flex 1 OCPU / 4 GB; subnet privada 10.0.2.0/24; sem IP público |
| `uniplus-standalone-postgres` | block volume 200 GB VPU 0, attached paravirtualized |
| `uniplus-standalone-kafka` | block volume 100 GB VPU 0 |
| `uniplus-standalone-minio` | block volume 200 GB VPU 0 |
| `uniplus-standalone-vault` | block volume 50 GB VPU 0 |

## Pré-requisitos

- OpenTofu ≥ 1.6 (testado com 1.11.6)
- `oci` CLI configurado (`~/.oci/config`) com permissão de `manage` para
  `instance-family` + `volume-family` no compartment alvo
- Acesso de leitura/escrita ao backend de state (atualmente local; ver §State)

## Setup inicial

```bash
cd provisioning/oci/standalone

# 1. Copiar o tfvars de exemplo e preencher OCIDs/SSH key
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# 2. Inicializar provider + plugins
tofu init

# 3. Plan inicial — neste primeiro run, Tofu vai propor CRIAR tudo do zero
#    porque o state está vazio e os recursos vivos ainda não foram importados.
tofu plan -out=plan.bin
```

## Importar recursos vivos (primeira vez)

State começa vazio mas os recursos JÁ EXISTEM no OCI. Importar antes de
qualquer apply para evitar duplicar (ou pior, sobrescrever) recursos vivos:

```bash
# Pegar OCIDs atuais
TENANCY="ocid1.tenancy.oc1..aaaaaaaa..."  # raiz da unifesspa-edu-br
oci compute instance list --compartment-id "$TENANCY" --all \
  | jq -r '.data[] | select(."display-name" | startswith("uniplus-standalone")) | "\(."display-name")=\(.id)"'
oci bv volume list --compartment-id "$TENANCY" --all \
  | jq -r '.data[] | select(."display-name" | startswith("uniplus-standalone")) | "\(."display-name")=\(.id)"'
oci compute volume-attachment list --compartment-id "$TENANCY" --all \
  | jq -r '.data[] | select(."lifecycle-state"=="ATTACHED") | "vol=\(."volume-id") attach=\(.id)"'

# Importar network (9 recursos: VCN + IGW + NAT + 2 RTs + 2 SLs + 2 subnets)
tofu import oci_core_vcn.this              ocid1.vcn.oc1.sa-saopaulo-1.<...>
tofu import oci_core_internet_gateway.this ocid1.internetgateway.oc1.sa-saopaulo-1.<...>
tofu import oci_core_nat_gateway.this      ocid1.natgateway.oc1.sa-saopaulo-1.<...>
tofu import oci_core_route_table.public    ocid1.routetable.oc1.sa-saopaulo-1.<...>
tofu import oci_core_route_table.private   ocid1.routetable.oc1.sa-saopaulo-1.<...>
tofu import oci_core_security_list.public  ocid1.securitylist.oc1.sa-saopaulo-1.<...>
tofu import oci_core_security_list.private ocid1.securitylist.oc1.sa-saopaulo-1.<...>
tofu import oci_core_subnet.public         ocid1.subnet.oc1.sa-saopaulo-1.<...>
tofu import oci_core_subnet.private        ocid1.subnet.oc1.sa-saopaulo-1.<...>

# Importar instances
tofu import oci_core_instance.k8s_host  ocid1.instance.oc1.sa-saopaulo-1.<...>
tofu import oci_core_instance.data_host ocid1.instance.oc1.sa-saopaulo-1.<...>

# Importar volumes (usando o for_each key)
tofu import 'oci_core_volume.data["postgres"]' ocid1.volume.oc1.sa-saopaulo-1.<postgres_ocid>
tofu import 'oci_core_volume.data["kafka"]'    ocid1.volume.oc1.sa-saopaulo-1.<kafka_ocid>
tofu import 'oci_core_volume.data["minio"]'    ocid1.volume.oc1.sa-saopaulo-1.<minio_ocid>
tofu import 'oci_core_volume.data["vault"]'    ocid1.volume.oc1.sa-saopaulo-1.<vault_ocid>

# Importar attachments
tofu import 'oci_core_volume_attachment.data["postgres"]' ocid1.volumeattachment.oc1.sa-saopaulo-1.<postgres_attachment_ocid>
tofu import 'oci_core_volume_attachment.data["kafka"]'    ocid1.volumeattachment.oc1.sa-saopaulo-1.<kafka_attachment_ocid>
tofu import 'oci_core_volume_attachment.data["minio"]'    ocid1.volumeattachment.oc1.sa-saopaulo-1.<minio_attachment_ocid>
tofu import 'oci_core_volume_attachment.data["vault"]'    ocid1.volumeattachment.oc1.sa-saopaulo-1.<vault_attachment_ocid>

# Re-plan — esperado: 0 changes (ou drift menor; ajustar HCL/variáveis até zerar)
tofu plan
```

## Operações típicas

```bash
# Ver estado atual + outputs
tofu show
tofu output

# Mudar perfil de capacidade (REBOOTA as VMs ~30-90s; ver scripts/resize-standalone-oci.sh)
$EDITOR terraform.tfvars   # profile = "hml"
tofu apply

# Aumentar tamanho dos blocks (in-place, online, sem reboot, sem perder dados)
$EDITOR terraform.tfvars   # volume_sizes_gbs.postgres = 500
tofu apply
# Pós-apply, estender o FS dentro da VM:
ssh ubuntu@164.152.53.29 "ssh ubuntu@10.0.2.87 'sudo lsblk; sudo growpart /dev/sdc 1; sudo resize2fs /dev/sdc1'"

# Diminuir tamanho dos blocks: NÃO suportado pela OCI (block volume só cresce).
# Tofu calcula in-place mas o API rejeita 400 no apply. Para encolher de fato,
# o caminho é destrutivo (delete + recreate via tofu destroy/apply ou criar
# volume novo + dd + swap manual). Não recomendado em POC — economia não
# compensa o risco; redimensionar para baixo é caso de migrar para infra nova.

# Recriar do zero (cuidado — destrutivo total)
tofu destroy
tofu apply
```

## State

State **local** por padrão (`terraform.tfstate` no diretório, ignorado pelo
`.gitignore`). Para uso em equipe, migrar para backend remoto — opção
sugerida: bucket OCI Object Storage com locking via `lockfile_resource`. Fora
do escopo desta versão; documentar em ADR-008 quando aplicável.

**Não commitar** `terraform.tfstate*` — contém OCIDs, IPs e potencialmente
dados sensíveis de configuração. `.gitignore` cuida disso.

## Limitações conhecidas

- **Default route table + default security list** do VCN são automaticamente
  criados pela OCI ao criar o VCN; ficam **não-gerenciados** pelo Tofu (não
  estão anexados a subnet alguma; SLs/RTs nomeadas cobrem o tráfego real).
  Se algum dia precisar gerenciar, adicionar `oci_core_default_route_table`
  e `oci_core_default_security_list` referenciando os OCIDs vivos via import.
- **NSGs (network security groups)** não criadas — Story #53 originalmente
  previa NSGs separadas para k8s-host e data-host (granularidade por VNIC).
  Implementação atual usa security lists por subnet — atende todas as
  necessidades; migração para NSG é refinamento futuro caso precise isolar
  tráfego entre VMs da mesma subnet.
- **DNS + Reserved Public IP**: na Story #56.
- **OCI Vault KMS** (auto-unseal Vault): na Story #57 (atualmente bloqueada
  por bug upstream `go-kms-wrapping@v2.0.9`).
- **IAM Dynamic Group + Policy** (resource principal): na Story #58.
- **Cloud-init**: VMs sobem com apenas `ssh_authorized_keys`. Re-bootstrap
  manual via `scripts/bootstrap-standalone.sh` continua necessário em
  recreate. cloud-init full (k3s + docker + LVM) fica para extensão da Story #54.
- **Boot volumes**: gerenciados implicitamente pelo `oci_core_instance.source_details`;
  recriar a VM recria o boot volume (perde estado do `/`).

## Próximos passos

| Story | Conteúdo |
|---|---|
| #56 | DNS A record + Reserved Public IP do k8s-host |
| #57 | OCI Vault, Master Encryption Key, Dynamic Group, IAM Policy (auto-unseal) |
| #58 | Bridge de outputs Tofu → `environments/standalone/values.yaml` |
