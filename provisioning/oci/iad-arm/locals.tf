locals {
  # Mapeamento de perfis para shape config (OCPU + memória) por host.
  # Sincronizar com scripts/resize-standalone-oci.sh quando este script ganhar
  # suporte a arm64 (Story #346/T3.1.x). Por enquanto o script só conhece
  # shapes E5.Flex — este módulo `iad-arm` declara o estado-alvo A1.Flex.
  #
  # poc_arm é o perfil-default: 3 OCPU / 16 GB total — cabe no Always Free
  # A1 (4 OCPU / 24 GB) com folga, idêntico em capacidade ao poc do `standalone`.
  # hml_arm extrapola Always Free; usar conscientemente (cobra ~$25/mês de A1
  # paga). Os perfis E5 (poc/hml) ficam declarados como referência histórica —
  # não selecionar via var.profile aqui pois A1.Flex rejeita configs de E5.Flex.
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
