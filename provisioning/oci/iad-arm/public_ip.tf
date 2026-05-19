# ==============================================================================
# Reserved Public IP do k8s-host (Story #56)
#
# RESERVED (vs EPHEMERAL) desacopla o IP da VM no nível da OCI: o recurso
# permanece alocado mesmo se a VM for terminada, e pode ser reanexado a uma
# instância nova via `private_ip_id`. ISSO É UMA PROPRIEDADE DO OCI, NÃO DO
# TOFU.
#
# ATENÇÃO: `tofu destroy` apaga `oci_core_public_ip.k8s_host` deste state e
# libera o IP para o pool da OCI — RESERVED não preserva contra destroy
# gerenciado pelo Tofu. Para preservar o IP entre destroy/apply, ver
# README.md → "Recriar do zero (CUIDADO)" com 2 workflows possíveis:
#   1. `lifecycle { prevent_destroy = true }` no recurso (destroy parcial)
#   2. `tofu state rm` antes do destroy + `tofu import` após apply
#
# Sem usar uma das duas, o próximo apply aloca um IP DIFERENTE e exige
# reconfigurar DNS, gov.br callback URL, certs Let's Encrypt, KC_HOSTNAME, etc.
#
# Custo: $0/h enquanto attached a uma VM running; $0.005/h (~$3.65/mês)
# enquanto não-atribuído.
#
# Diferente do `standalone/` (que importou IP pré-existente promovido
# manualmente), iad-arm é apply-from-zero — o IP é alocado novo no primeiro
# `tofu apply` e deve ser registrado no DNS / gov.br callback nesse momento.
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
  display_name   = "uniplus-iad-arm-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.k8s_host_primary.private_ips[0].id

  freeform_tags = local.common_tags
}
