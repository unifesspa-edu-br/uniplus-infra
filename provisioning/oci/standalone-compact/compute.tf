# ==============================================================================
# 2 VMs A1.Flex Always Free em GRU
#
# Always Free A1 Compute (home region only): 4 OCPU + 24 GB total per tenancy.
# Aloca-se 2/2 OCPU + 12/12 GB entre os 2 hosts. Mensal: ~2920 OCPU-hours
# (limite 3000) + ~17520 GB-hours (limite 18000). Margem 2.7%.
#
# Boot volumes Ubuntu 24.04 LTS aarch64 47 GB (mínimo). 2 × 47 = 94 GB.
# Combinado com 1 block 100 GB, total = 194 GB, dentro do Always Free Block
# Volume cap de 200 GB (também home region only).
# ==============================================================================

resource "oci_core_instance" "k8s_host" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = var.fault_domain
  display_name        = "uniplus-compact-k8s-host"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = local.shapes.k8s_host.ocpus
    memory_in_gbs = local.shapes.k8s_host.memory_in_gbs
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.k8s_host.id
    assign_public_ip = false # IP atribuído via Reserved Public IP em public_ip.tf
    hostname_label   = "k8s-host"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_keys
  }

  freeform_tags = local.common_tags

  lifecycle {
    # Mudanças em SSH key, image, ou tags forçam recreate — toleramos.
    # Mas mudança em shape_config faz live-resize (não-replace).
    ignore_changes = [defined_tags]
  }
}

resource "oci_core_instance" "data_host" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = var.fault_domain
  display_name        = "uniplus-compact-data-host"
  shape               = "VM.Standard.A1.Flex"

  shape_config {
    ocpus         = local.shapes.data_host.ocpus
    memory_in_gbs = local.shapes.data_host.memory_in_gbs
  }

  source_details {
    source_type = "image"
    source_id   = var.image_ocid
  }

  create_vnic_details {
    subnet_id        = oci_core_subnet.data_host.id
    assign_public_ip = true # IP efêmero para egress; sem Reserved IP no data-host
    hostname_label   = "data-host"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_keys
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [defined_tags]
  }
}
