# ==============================================================================
# 1 block volume único de 100 GB no data-host
#
# Always Free Block Volume (home region): 200 GB total combinando boot + block.
# 2 boot volumes × 47 GB = 94 GB + 1 block 100 GB = 194 GB (fits ≤ 200 GB).
#
# Para distribuir entre postgres/kafka/minio/vault, o bootstrap precisa
# particionar via LVM em LVs dedicados:
#
#   /dev/oracleoci/oraclevdb (100 GB block) →
#     PV → VG `uniplus-vg` → LVs:
#       lv-postgres (30 GB)
#       lv-kafka    (20 GB)
#       lv-minio    (40 GB)
#       lv-vault    (10 GB)
#
# Particionamento é responsabilidade do bootstrap script (precisa de
# refator Story #380 — discovery por display_name em vez de tamanho,
# já que aqui há só 1 disco em vez dos 4 distintos do standalone).
#
# Resize: aumentar tamanho é in-place online. Reduzir não é suportado pela
# OCI — se quiser shrink, criar volume novo + dd.
# ==============================================================================

resource "oci_core_volume" "data" {
  display_name        = "uniplus-compact-data"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  size_in_gbs         = var.volume_size_gbs
  vpus_per_gb         = var.volume_vpus_per_gb

  freeform_tags = local.common_tags
}

resource "oci_core_volume_attachment" "data" {
  attachment_type = "paravirtualized"
  instance_id     = oci_core_instance.data_host.id
  volume_id       = oci_core_volume.data.id
  display_name    = "att-data-host-uniplus-data"
  # Por display_name único, o bootstrap consegue identificar o role via
  # OCI instance metadata API (refator Story #380).
}
