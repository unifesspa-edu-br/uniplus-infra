locals {
  # Shape AMD E4.Flex PAYG mínimo para Uni+ POC.
  # 3 OCPU + 12 GB total ≈ ~$9,60/mês PAYG em GRU.
  # Pivot ARM→AMD após descoberta: A1 Always Free indisponível em GRU para
  # esta tenancy; A1 em outras regiões cai em PAYG (não-Free fora home region).
  #
  # Custo PAYG E4.Flex:
  #   OCPU: $0,0035/h × 3 × 730 = ~$7,66/mês
  #   Memory: $0,000217/GB-h × 12 × 730 = ~$1,90/mês
  #   Total compute: ~$9,60/mês
  # Block + boot volumes ficam Always Free (200 GB cap home region).
  shapes = {
    k8s_host  = { ocpus = 2, memory_in_gbs = 8 }
    data_host = { ocpus = 1, memory_in_gbs = 4 }
  }

  # OCI freeform_tags rejeita '/' em key names; usar underscore.
  common_tags = {
    "uniplus_environment" = "standalone-compact"
    "uniplus_managed_by"  = "opentofu"
  }

  # IP privado fixo do data-host. environments/standalone-compact/values.yaml
  # referencia este endereço para Postgres/Kafka/MinIO/Redis e para o scrape
  # do node-exporter. Mudá-lo exige atualizar o values.yaml em conjunto.
  data_host_private_ip = "10.2.2.11"
}
