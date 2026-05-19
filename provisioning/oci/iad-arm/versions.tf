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

# ------------------------------------------------------------------------------
# Provider alias `home_region` para recursos IAM master.
#
# IAM master definitions (Dynamic Groups, Policies, Users, Groups,
# Compartments) só podem ser criadas/alteradas a partir do endpoint IAM da
# HOME REGION da tenancy — independente da região onde compute/network/storage
# residem. Tentar criar via endpoint de outra região retorna
# `NotAuthorizedOrNotFound` (HTTP 404) no apply.
#
# A tenancy Uni+ foi criada em sa-saopaulo-1 (GRU) — esse é o home permanente
# (Oracle permite trocar apenas 1 vez via ticket de suporte). Como o module
# `iad-arm` aponta o provider default para us-ashburn-1, sem o alias o apply
# das IAM resources em kms.tf falharia, mesmo com compute/network válidos.
#
# A descoberta é dinâmica via data sources — sem variável de input nem
# hardcode — para o módulo permanecer correto se a home region for trocada
# no futuro.
#
# Refs:
#   https://docs.oracle.com/iaas/Content/Identity/regions/managingregions.htm
# ------------------------------------------------------------------------------

data "oci_identity_tenancy" "current" {
  tenancy_id = var.tenancy_ocid
}

data "oci_identity_regions" "all" {}

locals {
  home_region_name = one([
    for r in data.oci_identity_regions.all.regions :
    r.name if r.key == data.oci_identity_tenancy.current.home_region_key
  ])
}

provider "oci" {
  alias  = "home_region"
  region = local.home_region_name
  # Auth herda do mesmo ~/.oci/config do provider default.
}
