terraform {
  required_version = ">= 1.6.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.7"
    }
  }
}

provider "oci" {
  region = var.region
  # Auth via ~/.oci/config (`tenancy_ocid` + `user_ocid` + `fingerprint` + `private_key_path`).
  # Tenancy home region = sa-saopaulo-1 — coincide com este módulo, então NÃO é
  # necessário um provider alias `home_region` separado (diferente do `iad-arm/`
  # que aponta para us-ashburn-1 e precisa do alias para IAM master ops).
}
