# ==============================================================================
# 2 VMs E4.Flex AMD PAYG em GRU (home region)
#
# Pivot ARM→AMD (2026-05-19): A1 Always Free indisponível em GRU para esta
# tenancy; A1 PAYG em região não-home perdia o benefício free. Voltamos para
# AMD E4.Flex (PAYG GRU) com footprint reduzido (~$9,60/mês compute total).
#
# Boot volumes Ubuntu 24.04 LTS x86_64 47 GB (mínimo). 2 × 47 = 94 GB.
# Combinado com 1 block 100 GB, total = 194 GB, dentro do Always Free Block
# Volume cap de 200 GB (home region — ainda aplica para esta tenancy em GRU).
# ==============================================================================

resource "oci_core_instance" "k8s_host" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = var.fault_domain
  display_name        = "uniplus-compact-k8s-host"
  shape               = "VM.Standard.E4.Flex"

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
  shape               = "VM.Standard.E4.Flex"

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
