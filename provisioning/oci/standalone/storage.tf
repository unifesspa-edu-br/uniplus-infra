# ==============================================================================
# Block volumes do data-host
#
# 4 volumes anexados via paravirtualized — montagens LVM (`uniplus-vg/<lv>`)
# feitas pelo `bootstrap-standalone.sh --role=standalone-data`. Reduzir
# `volume_sizes_gbs` em terraform.tfvars é destrutivo: OCI não permite
# encolher block volume; Tofu vai delete + recreate, perdendo dados.
#
# Para shrink (POC: 200/100/200/50 → 10/10/10/10):
#   1. Backup de dados críticos (Vault Shamir, KC realm — embora realm.json
#      esteja em git)
#   2. Editar terraform.tfvars → volume_sizes_gbs = { postgres=10, kafka=10,
#      minio=10, vault=10 }
#   3. tofu apply — confirma 4 destroy + 4 create
#   4. Re-bootstrap via bootstrap-standalone.sh (LVM nova; vault re-init;
#      kc realm re-import; demais apps reconciliados pelo ArgoCD)
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

  display_name        = "uniplus-standalone-${each.key}"
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
  # para `uniplus-standalone-...-attachment` faria detach/reattach (perde
  # mounts ativos no data-host).
  display_name = "att-${each.key}"
}
