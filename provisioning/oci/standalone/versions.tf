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
  # Alternativas: instance principal, resource principal, security token.
}
