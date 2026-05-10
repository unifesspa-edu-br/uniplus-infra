# OpenTofu — standalone OCI

Provisionamento OpenTofu do ambiente standalone Uni+ na OCI (sa-saopaulo-1).
Cobertura: VCN + 2 subnets + IGW + NAT GW + 2 route tables + 2 security
lists + 2 VMs E5.Flex + 4 block volumes do data-host + Reserved Public IP
do k8s-host + 11 DNS records do subdomínio `*.standalone.portaluni.com.br`
(Stories #52, #53, #54, #55 e #56 da Feature #43). KMS auto-unseal (#57)
e bridge para Helm (#58) ficam fora deste recorte.

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
| `uniplus-standalone-ip` | Reserved Public IP, anexado ao primary VNIC do k8s-host. Sobrevive a `tofu destroy/apply`. Atual: `164.152.53.29`. |

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

# Importar Reserved Public IP do k8s-host (1 recurso)
tofu import oci_core_public_ip.k8s_host    ocid1.publicip.oc1.sa-saopaulo-1.<...>

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

# Importar DNS rrsets (1 A apex + 10 CNAMEs).
# Atenção ao formato chave/valor: provider OCI exige `zoneNameOrId/<id>/domain/<dom>/rtype/<rt>`,
# não slash simples — slash simples falha com `can not marshal to path in request`.
ZONE=ocid1.dns-zone.oc1..<...>
tofu import oci_dns_rrset.standalone_apex \
  "zoneNameOrId/$ZONE/domain/standalone.portaluni.com.br/rtype/A"
for sub in api-ingresso api-portal api-selecao ingresso kafka-ui minio portal redis-ui schema-registry selecao; do
  tofu import "oci_dns_rrset.standalone_cname[\"$sub\"]" \
    "zoneNameOrId/$ZONE/domain/$sub.standalone.portaluni.com.br/rtype/CNAME"
done

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

## Bridge para os charts Helm (Story #58)

Outputs do Tofu não chegam automaticamente nos charts Helm — ArgoCD lê
valores do `environments/standalone/values.yaml` (em git), não do state
Tofu. A bridge entre os dois mundos é o script
[`scripts/sync-tofu-outputs.sh`](../../../scripts/sync-tofu-outputs.sh):

```bash
# Tabela com todos os outputs e onde cada um aparece em values.yaml
./scripts/sync-tofu-outputs.sh

# Detecta drift entre IPs/FQDN do Tofu e o que está hardcoded no values.yaml
./scripts/sync-tofu-outputs.sh --diff

# Cria/atualiza ConfigMap K8s `standalone-tofu-outputs` no namespace
# `uniplus` com TODOS os outputs como chaves planas. Útil para charts
# (ex.: Vault — Story #57) consumirem via envFrom/valueFrom sem precisar
# duplicar valores em values.yaml.
./scripts/sync-tofu-outputs.sh --apply-configmap [--namespace=uniplus]
```

**Estratégia de bridge** (compatível com GitOps):

- Schema do `environments/standalone/values.yaml` continua **provider-agnostic**;
  é versionado em git e lido pelo ArgoCD.
- Valores OCI-specific (IPs, hostnames) ficam **hardcoded** no `values.yaml`
  para o ArgoCD ter tudo no repo. Recreate de infra que mude algum desses
  valores exige PR ajustando o `values.yaml`. O `--diff` ajuda a detectar
  divergência cedo.
- Outputs sensíveis ou OCID-only (ex.: `vcn_ocid`, OCIDs do KMS futuro
  da Story #57) **não** entram em `values.yaml` — ficam no `ConfigMap` K8s
  populado por `--apply-configmap`. Charts os consomem via `envFrom`.

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
- **OCI Vault KMS** (auto-unseal Vault): na Story #57 (atualmente bloqueada
  por bug upstream `go-kms-wrapping@v2.0.9`).
- **IAM Dynamic Group + Policy** (resource principal): na Story #58.
- **Cloud-init**: VMs sobem com apenas `ssh_authorized_keys`. Re-bootstrap
  manual via `scripts/bootstrap-standalone.sh` continua necessário em
  recreate. cloud-init full (k3s + docker + LVM) fica para extensão da Story #54.
- **Boot volumes**: gerenciados implicitamente pelo `oci_core_instance.source_details`;
  recriar a VM recria o boot volume (perde estado do `/`).

## Próximos passos

| Story | Conteúdo | Bloqueio |
|---|---|---|
| #57 | OCI Vault, Master Encryption Key, Dynamic Group, IAM Policy (auto-unseal) | bug `go-kms-wrapping@v2.0.9` |
