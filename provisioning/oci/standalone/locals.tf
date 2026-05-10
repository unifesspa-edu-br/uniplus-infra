locals {
  # Mapeamento de perfis para shape config (OCPU + memória) por host.
  # Sincronizar com scripts/resize-standalone-oci.sh — esse arquivo declara
  # o estado-alvo, o script é a alternativa imperativa via OCI CLI.
  shape_profiles = {
    poc = {
      k8s_host  = { ocpus = 2, memory_in_gbs = 12 }
      data_host = { ocpus = 1, memory_in_gbs = 4 }
    }
    hml = {
      k8s_host  = { ocpus = 4, memory_in_gbs = 24 }
      data_host = { ocpus = 2, memory_in_gbs = 16 }
    }
  }

  shapes = local.shape_profiles[var.profile]

  # OCI freeform_tags rejeita '/' em key names; usar underscore.
  common_tags = {
    "uniplus_environment" = "standalone"
    "uniplus_managed_by"  = "opentofu"
  }
}
