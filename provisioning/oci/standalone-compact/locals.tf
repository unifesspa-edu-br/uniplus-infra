locals {
  # Shape fixo Always Free A1: 4 OCPU / 24 GB total dividido entre os 2 hosts.
  # Não há "profile poc/hml" como em standalone/ — qualquer config acima disso
  # sai do free tier. Mantenho a alocação balanceada 2/2 para igualar carga.
  #
  # Always Free A1 Compute mensal:
  #   3000 OCPU-hours / 18000 GB-hours
  #   4 OCPU × 730h = 2920 OCPU-hours  (cabe, margem 2.7%)
  #   24 GB × 730h = 17520 GB-hours    (cabe, margem 2.7%)
  shapes = {
    k8s_host  = { ocpus = 2, memory_in_gbs = 12 }
    data_host = { ocpus = 2, memory_in_gbs = 12 }
  }

  # OCI freeform_tags rejeita '/' em key names; usar underscore.
  common_tags = {
    "uniplus_environment" = "standalone-compact"
    "uniplus_managed_by"  = "opentofu"
  }
}
