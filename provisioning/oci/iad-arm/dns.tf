# ==============================================================================
# DNS records do iad-arm (lab paralelo durante a migração GRU → IAD)
#
# A zona `portaluni.com.br` é hospedada na OCI DNS (já existente em
# sa-saopaulo-1, NÃO gerenciada por este código — é compartilhada com outros
# ambientes da plataforma). Aqui declaramos apenas os records do subdomínio
# `iad-arm.portaluni.com.br`, paralelos a `standalone.portaluni.com.br` que
# continua apontando para o lab GRU durante a janela de migração.
#
# Topologia:
#   iad-arm.portaluni.com.br      A     <reserved-ip-iad>
#   <serviço>.iad-arm.portaluni…  CNAME iad-arm.portaluni.com.br.
#
# CNAMEs cobrem cada serviço exposto pelo Traefik no k8s-host. Adicionar
# novo serviço = adicionar 1 entry em local.iad_arm_cnames.
#
# Cutover final (Story #359): reapontar o domínio canônico (a definir na
# Story — `standalone.portaluni.com.br` ou um novo `lab.portaluni.com.br`)
# para os IPs IAD, destruir o lab GRU, e decidir se mantém ou destrói os
# records `iad-arm.*` após o corte.
#
# Import format (provider OCI):
#   tofu import oci_dns_rrset.<name> \
#     "zoneNameOrId/<zone-ocid>/domain/<fqdn>/rtype/<TYPE>"
# (Formato chave/valor — slash simples NÃO funciona.)
# ==============================================================================

data "oci_dns_zones" "portaluni" {
  # A zona é um recurso de plataforma compartilhada — vive no tenancy root,
  # não no compartment de workload (mesmo quando ambos coincidem hoje no POC).
  # Usar `var.tenancy_ocid` garante o lookup correto se algum operador isolar
  # workload em child compartment no futuro. Caso contrário, `zones[0]` virá
  # vazio e `tofu plan` quebra antes de criar qualquer registro.
  compartment_id = var.tenancy_ocid
  name           = "portaluni.com.br"
  scope          = "GLOBAL"
}

locals {
  dns_zone_id = data.oci_dns_zones.portaluni.zones[0].id
  apex_domain = "iad-arm.portaluni.com.br"

  # Subdomínios CNAME que apontam para o apex `iad-arm.portaluni.com.br`.
  # Adicionar entry aqui = `tofu apply` cria o RRset novo.
  iad_arm_cnames = toset([
    "api-ingresso",
    "api-portal",
    "api-selecao",
    "ingresso",
    "kafka-ui",
    "minio",
    "portal",
    "redis-ui",
    "schema-registry",
    "selecao",
  ])
}

resource "oci_dns_rrset" "iad_arm_apex" {
  zone_name_or_id = local.dns_zone_id
  domain          = local.apex_domain
  rtype           = "A"

  items {
    domain = local.apex_domain
    rtype  = "A"
    rdata  = oci_core_public_ip.k8s_host.ip_address
    ttl    = 300
  }
}

resource "oci_dns_rrset" "iad_arm_cname" {
  for_each = local.iad_arm_cnames

  zone_name_or_id = local.dns_zone_id
  domain          = "${each.key}.${local.apex_domain}"
  rtype           = "CNAME"

  items {
    domain = "${each.key}.${local.apex_domain}"
    rtype  = "CNAME"
    # CNAMEs OCI sempre terminam em ponto.
    rdata = "${local.apex_domain}."
    ttl   = 300
  }
}
