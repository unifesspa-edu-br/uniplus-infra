# ==============================================================================
# OCI KMS para auto-unseal do HashiCorp Vault (Story #57)
#
# 4 recursos:
#   - oci_kms_vault.unseal       container OCI das keys (DEFAULT, software-backed)
#   - oci_kms_key.unseal         AES-256 envelope key usada pelo seal "ocikms"
#   - oci_identity_dynamic_group.k8s_host  matches instance.id do k8s-host
#   - oci_identity_policy.vault_unseal     allow DG to use keys + vaults
#
# Endpoints derivados (outputs):
#   - kms_management_endpoint    https://<id>-management.kms.<region>.oraclecloud.com
#   - kms_crypto_endpoint        https://<id>-crypto.kms.<region>.oraclecloud.com
#
# Esses 4 valores (key_id + crypto_endpoint + management_endpoint + auth_type)
# alimentam o bloco `seal "ocikms"` no extraconfig do chart `platform/vault`,
# permitindo unseal automático sem precisar de operator unseal manual a cada
# restart. Story #64 cobre o re-init do Vault apontando pra esse seal type.
#
# Auth do Vault contra OCI KMS é via Resource Principal — `auth_type_api_key
# = "false"` no seal block. O pod do Vault assume identidade do k8s-host
# (instance principal); como instance.id está no DG, e o DG tem permissão
# `use keys`, o Vault opera sem credenciais explícitas.
# ==============================================================================

resource "oci_kms_vault" "unseal" {
  compartment_id = var.compartment_ocid
  display_name   = "uniplus-iad-arm-vault-kms"
  vault_type     = "DEFAULT"

  freeform_tags = local.common_tags
}

resource "oci_kms_key" "unseal" {
  compartment_id      = var.compartment_ocid
  display_name        = "uniplus-iad-arm-vault-unseal-key"
  management_endpoint = oci_kms_vault.unseal.management_endpoint
  protection_mode     = "SOFTWARE"

  key_shape {
    algorithm = "AES"
    length    = 32 # bytes — AES-256
  }

  freeform_tags = local.common_tags
}

resource "oci_identity_dynamic_group" "k8s_host" {
  # Dynamic Groups vivem no tenancy raiz (não no compartment do recurso).
  compartment_id = var.compartment_ocid
  name           = "uniplus-iad-arm-k8s-host-dg"
  description    = "Dynamic Group para o k8s-host do ambiente iad-arm — permite auto-unseal do Vault via OCI KMS"
  matching_rule  = "ANY {instance.id = '${oci_core_instance.k8s_host.id}'}"

  freeform_tags = local.common_tags
}

resource "oci_identity_policy" "vault_unseal" {
  compartment_id = var.compartment_ocid
  name           = "uniplus-iad-arm-vault-unseal-policy"
  description    = "Permite que o k8s-host use a chave KMS para auto-unseal do HashiCorp Vault"
  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.k8s_host.name} to use keys in tenancy where target.key.id = '${oci_kms_key.unseal.id}'",
    "Allow dynamic-group ${oci_identity_dynamic_group.k8s_host.name} to use vaults in tenancy where target.vault.id = '${oci_kms_vault.unseal.id}'",
  ]

  freeform_tags = local.common_tags
}
