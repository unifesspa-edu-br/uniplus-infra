# ==============================================================================
# DNS records do standalone (parte deferida da Story #56, fechada por #208)
#
# A zona `portaluni.com.br` é hospedada na OCI DNS (já existente, NÃO
# gerenciada por este código — é compartilhada com outros ambientes da
# plataforma). Aqui declaramos apenas os records do subdomínio `standalone`.
#
# Topologia:
#   standalone.portaluni.com.br      A     <reserved-ip>
#   <serviço>.standalone.portaluni…  CNAME standalone.portaluni.com.br.
#
# CNAMEs cobrem cada serviço exposto pelo Traefik no k8s-host. Adicionar
# novo serviço = adicionar 1 entry em local.standalone_cnames.
#
# Import format (provider OCI):
#   tofu import oci_dns_rrset.<name> \
#     "zoneNameOrId/<zone-ocid>/domain/<fqdn>/rtype/<TYPE>"
# (Formato chave/valor — slash simples NÃO funciona.)
# ==============================================================================

data "oci_dns_zones" "portaluni" {
  compartment_id = var.compartment_ocid
  name           = "portaluni.com.br"
  scope          = "GLOBAL"
}

locals {
  dns_zone_id = data.oci_dns_zones.portaluni.zones[0].id
  apex_domain = "standalone.portaluni.com.br"

  # Subdomínios CNAME que apontam para o apex `standalone.portaluni.com.br`.
  # Adicionar entry aqui = `tofu apply` cria o RRset novo.
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
    # CNAMEs OCI sempre terminam em ponto.
    rdata = "${local.apex_domain}."
    ttl   = 300
  }
}
