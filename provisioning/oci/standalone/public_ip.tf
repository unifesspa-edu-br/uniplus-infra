# ==============================================================================
# Reserved Public IP do k8s-host (Story #56)
#
# RESERVED (vs EPHEMERAL) garante que o IP sobreviva a `tofu destroy && tofu
# apply`: o IP é um recurso desacoplado da VM, anexado via `private_ip_id`.
# Recriar a VM mantém o mesmo IP, evitando reconfigurar DNS, gov.br
# callback URL, certs Let's Encrypt, KC_HOSTNAME, etc.
#
# Custo: $0/h enquanto attached a uma VM running; $0.005/h (~$3.65/mês)
# enquanto não-atribuído.
#
# Como o standalone vivo nasceu com IP ephemeral promovido manualmente para
# RESERVED via OCI CLI, basta importar para o Tofu — o IP `164.152.53.29`
# fica preservado.
# ==============================================================================

data "oci_core_vnic_attachments" "k8s_host" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.k8s_host.id
}

data "oci_core_private_ips" "k8s_host_primary" {
  vnic_id = data.oci_core_vnic_attachments.k8s_host.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "k8s_host" {
  compartment_id = var.compartment_ocid
  display_name   = "uniplus-standalone-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.k8s_host_primary.private_ips[0].id

  freeform_tags = local.common_tags
}
