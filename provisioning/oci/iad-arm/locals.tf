locals {
  # Mapeamento de perfis para shape config (OCPU + memória) por host.
  # Sincronizar com scripts/resize-standalone-oci.sh quando este script ganhar
  # suporte a arm64 (Story #346/T3.1.x). Por enquanto o script só conhece
  # shapes E5.Flex — este módulo `iad-arm` declara o estado-alvo A1.Flex.
  #
  # poc_arm é o perfil-default: 3 OCPU / 16 GB total — idêntico em capacidade
  # ao poc do `standalone`. Compute em IAD vai para PAYG (~$39/mês) porque
  # Always Free A1 é home-region-only (home = GRU); ver README.md →
  # "Gate de validação operacional" para o smoke test que pode reverter
  # essa premissa caso billing mostre Always Free aplicando cross-region.
  # hml_arm: 6 OCPU / 40 GB total — ~$86/mês compute em IAD PAYG. Total
  # com storage + NAT GW ~$127/mês, já ultrapassando o GRU; só faz sentido
  # pós elimination do NAT GW.
  shape_profiles = {
    poc_arm = {
      k8s_host  = { ocpus = 2, memory_in_gbs = 12 }
      data_host = { ocpus = 1, memory_in_gbs = 4 }
    }
    hml_arm = {
      k8s_host  = { ocpus = 4, memory_in_gbs = 24 }
      data_host = { ocpus = 2, memory_in_gbs = 16 }
    }
  }

  shapes = local.shape_profiles[var.profile]

  # OCI freeform_tags rejeita '/' em key names; usar underscore.
  common_tags = {
    "uniplus_environment" = "iad-arm"
    "uniplus_managed_by"  = "opentofu"
  }
}
