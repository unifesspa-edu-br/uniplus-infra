# ==============================================================================
# DNS records do standalone-compact
#
# Zona `portaluni.com.br` é compartilhada (mora no tenancy root). O compact
# assumiu o domínio canônico `standalone.portaluni.com.br` no cutover de
# 2026-05-19 (A record reapontado do IP do lab antigo 164.152.53.29 para o
# Reserved Public IP do compact). O lab `standalone/` antigo foi destruído.
#
# O apex `standalone.portaluni.com.br` aponta para o Reserved Public IP do
# k8s-host; os demais hosts são CNAMEs para o apex. Os IngressRoutes e as
# URLs OIDC em environments/standalone-compact/values.yaml usam exatamente
# estes nomes — manter o domínio em sincronia com o values.yaml.
# ==============================================================================

data "oci_dns_zones" "portaluni" {
  # A zona é recurso de plataforma compartilhada — vive no tenancy root.
  compartment_id = var.tenancy_ocid
  name           = "portaluni.com.br"
  scope          = "GLOBAL"
}

locals {
  dns_zone_id = data.oci_dns_zones.portaluni.zones[0].id
  apex_domain = "standalone.portaluni.com.br"

  standalone_cnames = toset([
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

resource "oci_dns_rrset" "standalone_apex" {
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

resource "oci_dns_rrset" "standalone_cname" {
  for_each = local.standalone_cnames

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
