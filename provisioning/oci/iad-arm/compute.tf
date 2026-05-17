# ==============================================================================
# k8s-host — VM pública que roda k3s + Helm + ArgoCD + apps Uni+
# ==============================================================================
resource "oci_core_instance" "k8s_host" {
  display_name        = "uniplus-iad-arm-k8s-host"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = var.fault_domain
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
    subnet_id = oci_core_subnet.public.id
    # `assign_public_ip = false`: o IP público do k8s-host vem do
    # `oci_core_public_ip.k8s_host` (RESERVED, definido em public_ip.tf),
    # anexado ao primary private IP via `private_ip_id`. Setar `true`
    # aqui criaria um IP EPHEMERAL e o `oci_core_public_ip` falharia
    # depois com "private IP already has a public IP assigned" — diferente
    # do `standalone/` (que tem `true` mas só funciona porque foi
    # importado após promoção manual EPHEMERAL→RESERVED via OCI CLI;
    # `iad-arm` é apply from zero).
    assign_public_ip = false
    hostname_label   = "k8s-host"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_keys
  }

  freeform_tags = local.common_tags

  # bootstrap-standalone.sh provisiona k3s/helm/argocd; cloud-init full vai
  # numa Story de extensão. Por enquanto, recriar a VM exige rodar o script
  # manualmente após o apply.
  lifecycle {
    ignore_changes = [
      # source_details muda quando OCI bumpa a imagem Ubuntu LTS — não force
      # recreate por isso.
      source_details,
    ]
  }
}

# ==============================================================================
# data-host — VM privada que roda Postgres + Kafka + Redis + MinIO via systemd
# ==============================================================================
resource "oci_core_instance" "data_host" {
  display_name        = "uniplus-iad-arm-data-host"
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  fault_domain        = var.fault_domain
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
    subnet_id        = oci_core_subnet.private.id
    assign_public_ip = false
    hostname_label   = "data-host"
  }

  metadata = {
    ssh_authorized_keys = var.ssh_authorized_keys
  }

  freeform_tags = local.common_tags

  lifecycle {
    ignore_changes = [source_details]
  }
}
