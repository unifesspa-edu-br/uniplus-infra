# ==============================================================================
# OCI KMS para auto-unseal do HashiCorp Vault (paralelo a standalone/ Story #57)
#
# 4 recursos:
#   - oci_kms_vault.unseal       container OCI das keys (DEFAULT, software-backed)
#   - oci_kms_key.unseal         AES-256 envelope key usada pelo seal "ocikms"
#   - oci_identity_dynamic_group.k8s_host  matches instance.id do k8s-host
#   - oci_identity_policy.vault_unseal     allow DG to use keys + vaults
#
# IAM Dynamic Group e Policy NÃO precisam de provider alias `home_region` aqui
# porque o módulo já roda em sa-saopaulo-1 = home da tenancy. Diferença
# crítica vs `iad-arm/` que aponta provider default para IAD.
# ==============================================================================

resource "oci_kms_vault" "unseal" {
  compartment_id = var.compartment_ocid
  display_name   = "uniplus-compact-vault-kms"
  vault_type     = "DEFAULT"

  freeform_tags = local.common_tags
}

resource "oci_kms_key" "unseal" {
  compartment_id      = var.compartment_ocid
  display_name        = "uniplus-compact-vault-unseal-key"
  management_endpoint = oci_kms_vault.unseal.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32 # bytes — AES-256
  }

  freeform_tags = local.common_tags
}

resource "oci_identity_dynamic_group" "k8s_host" {
  # IAM Dynamic Groups são tenancy-scoped: compartment_id aponta para o root.
  compartment_id = var.tenancy_ocid
  name           = "uniplus-compact-k8s-host-dg"
  description    = "Dynamic Group para o k8s-host do compact — permite auto-unseal do Vault via OCI KMS"
  matching_rule  = "ANY {instance.id = '${oci_core_instance.k8s_host.id}'}"

  freeform_tags = local.common_tags
}

resource "oci_identity_policy" "vault_unseal" {
  compartment_id = var.tenancy_ocid
  name           = "uniplus-compact-vault-unseal-policy"
  description    = "Permite que o k8s-host use a chave KMS para auto-unseal do HashiCorp Vault"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.k8s_host.name} to use keys in tenancy where target.key.id = '${oci_kms_key.unseal.id}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.k8s_host.name} to use vaults in tenancy where target.vault.id = '${oci_kms_vault.unseal.id}'",
  ]

  freeform_tags = local.common_tags
}
