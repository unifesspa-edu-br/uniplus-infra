# ==============================================================================
# Reserved Public IP do k8s-host
#
# RESERVED (não EPHEMERAL) para sobreviver a recreate da VM. RESERVED no nível
# do OCI desacopla o IP da VM — pode ser reanexado a uma nova instância via
# `private_ip_id`. Sem isso, qualquer recreate aloca IP novo e rotaciona DNS,
# gov.br callbacks, certs Let's Encrypt, KC_HOSTNAME etc.
#
# ATENÇÃO: `tofu destroy` apaga este recurso do state e libera o IP. Para
# preservar entre destroy/apply, ver duas sequências:
#
#   A. `tofu destroy -exclude=oci_core_public_ip.k8s_host` + `tofu apply`
#      (OpenTofu ≥ 1.9; preferido — uma única flag)
#   B. `tofu state rm` + `tofu destroy` + `tofu import <ocid>` + `tofu apply`
#      (compatível < 1.9; precisa salvar OCID e importar ANTES do apply)
#
# Custo: $0/h enquanto attached a uma VM running; $0.005/h (~$3.65/mês)
# enquanto não-atribuído.
#
# Diferente do `iad-arm/` (apply-from-zero ARM), aqui herdamos a tradição
# do `standalone/` — IP novo é alocado no primeiro apply, registrado no DNS
# nesse momento.
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
  display_name   = "uniplus-compact-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.k8s_host_primary.private_ips[0].id

  freeform_tags = local.common_tags
}
