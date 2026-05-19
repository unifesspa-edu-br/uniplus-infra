# ==============================================================================
# DNS records do standalone-compact
#
# Zona `portaluni.com.br` é compartilhada (mora no tenancy root). Registramos
# o subdomínio `compact.portaluni.com.br` em paralelo a:
#   standalone.portaluni.com.br (lab GRU antigo, VMs OFF)
#   iad-arm.portaluni.com.br    (lab IAD draft, não-deployado)
#
# Cutover futuro: quando este compact estiver bootstrap concluído e validado,
# reapontar o domínio canônico (a definir) para o IP do compact e destruir o
# lab `standalone/` antigo.
# ==============================================================================

data "oci_dns_zones" "portaluni" {
  # A zona é recurso de plataforma compartilhada — vive no tenancy root.
  compartment_id = var.tenancy_ocid
  name           = "portaluni.com.br"
  scope          = "GLOBAL"
}

locals {
  dns_zone_id = data.oci_dns_zones.portaluni.zones[0].id
  apex_domain = "compact.portaluni.com.br"

  compact_cnames = toset([
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

resource "oci_dns_rrset" "compact_apex" {
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

resource "oci_dns_rrset" "compact_cname" {
  for_each = local.compact_cnames

  zone_name_or_id = local.dns_zone_id
  domain          = "${each.key}.${local.apex_domain}"
  rtype           = "CNAME"

  items {
    domain = "${each.key}.${local.apex_domain}"
    rtype  = "CNAME"
    rdata  = "${local.apex_domain}."
    ttl    = 300
  }
}
