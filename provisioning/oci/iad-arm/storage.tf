# ==============================================================================
# Block volumes do data-host
#
# 4 volumes anexados via paravirtualized — montagens LVM (`uniplus-vg/<lv>`)
# feitas pelo `bootstrap-standalone.sh --role=standalone-data`.
#
# Resize do `volume_sizes_gbs`:
#   - **Aumentar** (ex.: 200→500): in-place, online, sem reboot, sem perder
#     dados. OCI provider trata `size_in_gbs` como atributo updateable.
#     `tofu apply` chama UpdateVolume; resize é segundos no OCI side.
#     Pós-apply, é necessário ESTENDER o sistema de arquivos dentro da VM:
#       ssh ubuntu@10.0.2.87
#       sudo lsblk                  # confirmar nome do device (ex.: sdc)
#       sudo growpart /dev/sdc 1    # estende a partição (cloud-utils)
#       sudo resize2fs /dev/sdc1    # ext4; ou xfs_growfs <mountpoint>
#
#   - **Diminuir** (ex.: 200→100): NÃO suportado pela OCI. Tofu calcula
#     "in-place" mas o API rejeita com 400 no apply. Para encolher é
#     necessário processo manual destrutivo: criar volume novo menor,
#     `dd`/`rsync` dos dados, swap do attachment, delete do antigo.
#     **Não recomendado em POC** — economia (<$10/mês) não compensa risco
#     de perda de dados; usar VM nova (`tofu destroy && apply` com
#     tamanhos menores em tfvars) é mais limpo.
# ==============================================================================
locals {
  data_volumes = {
    postgres = { size_gbs = var.volume_sizes_gbs.postgres }
    kafka    = { size_gbs = var.volume_sizes_gbs.kafka }
    minio    = { size_gbs = var.volume_sizes_gbs.minio }
    vault    = { size_gbs = var.volume_sizes_gbs.vault }
  }
}

resource "oci_core_volume" "data" {
  for_each = local.data_volumes

  display_name        = "uniplus-iad-arm-${each.key}"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  size_in_gbs         = each.value.size_gbs
  vpus_per_gb         = var.volume_vpus_per_gb

  freeform_tags = local.common_tags
}

resource "oci_core_volume_attachment" "data" {
  for_each = local.data_volumes

  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.data_host.id
  volume_id       = oci_core_volume.data[each.key].id
  # `att-<vol>` é o display_name do recurso vivo (provisionado manualmente em
  # 2026-05-04). OCI provider força replacement ao mudar display_name; trocar
  # para `uniplus-iad-arm-...-attachment` faria detach/reattach (perde
  # mounts ativos no data-host).
  display_name = "att-${each.key}"
}
