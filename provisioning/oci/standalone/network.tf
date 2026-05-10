# ==============================================================================
# Network — VCN + 2 subnets + IGW + NAT GW + route tables + security lists
#
# Topologia:
#
#                        Internet
#                            │
#                          ┌─┴─┐
#                          │IGW│
#                          └─┬─┘
#         RT public ─────────┘
#         (0.0.0.0/0 → IGW)
#                │
#         ┌──────▼──────────────────────┐
#         │ subnet-public  10.0.1.0/24  │
#         │ - k8s-host (10.0.1.61)      │
#         │ - SL: 22/80/443 from world  │
#         └──────────────┬──────────────┘
#                        │ intra-VCN
#         ┌──────────────▼──────────────┐
#         │ subnet-private 10.0.2.0/24  │
#         │ - data-host (10.0.2.87)     │
#         │ - SL: 22/5432/6379/9000-1/  │
#         │       9092/icmp from VCN    │
#         └──────────────┬──────────────┘
#                        │
#         RT private ────┘
#         (0.0.0.0/0 → NAT GW)
#                │
#              ┌─▼─┐
#              │NAT│ 137.131.206.254 (egress only)
#              └─┬─┘
#                ▼
#             Internet
#
# Decisões:
# - Default route table + default security list do VCN ficam não-gerenciados
#   pelo Tofu (recursos automáticos da OCI ao criar VCN; não anexados a
#   nenhuma subnet aqui).
# - Story #53 originalmente especificava NSGs separadas para k8s-host
#   (22/80/443) e data-host (5432/6379/9000-1/9092). Implementação viva usa
#   security lists por subnet — já cobre todas as necessidades sem
#   granularidade adicional. Migração para NSG (mais granular, por VNIC)
#   fica como refinamento futuro caso precise isolar tráfego entre VMs da
#   mesma subnet.
# - SSH na subnet privada vem de toda a VCN (10.0.0.0/16) para permitir
#   jump via k8s-host. Restringir a 10.0.1.0/24 (só subnet pública) é
#   refinamento de hardening futuro.
# ==============================================================================

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  display_name   = "uniplus-standalone-vcn"
  cidr_blocks    = [var.vcn_cidr]
  dns_label      = "unipluslab"

  freeform_tags = local.common_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-standalone-igw"
  enabled        = true

  freeform_tags = local.common_tags
}

resource "oci_core_nat_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-standalone-natgw"
  block_traffic  = false

  freeform_tags = local.common_tags
}

resource "oci_core_route_table" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-standalone-rt-public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  freeform_tags = local.common_tags
}

resource "oci_core_route_table" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-standalone-rt-private"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_nat_gateway.this.id
  }

  freeform_tags = local.common_tags
}

# Security lists — uma por subnet. Egress all (default OCI). Ingress aplicado
# por porta + origem (0.0.0.0/0 na pública, intra-VCN na privada).
resource "oci_core_security_list" "public" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-standalone-sl-public"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH admin
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6" # TCP
    description = "SSH"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # HTTP (Traefik / cert-manager HTTP-01)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    description = "HTTP"
    tcp_options {
      min = 80
      max = 80
    }
  }

  # HTTPS (Traefik)
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    description = "HTTPS"
    tcp_options {
      min = 443
      max = 443
    }
  }

  freeform_tags = local.common_tags
}

resource "oci_core_security_list" "private" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-standalone-sl-private"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH (jump via k8s-host)
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "6"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # Postgres
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "6"
    tcp_options {
      min = 5432
      max = 5432
    }
  }

  # Redis
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "6"
    tcp_options {
      min = 6379
      max = 6379
    }
  }

  # MinIO API (9000) + Console (9001)
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "6"
    tcp_options {
      min = 9000
      max = 9001
    }
  }

  # Kafka SASL_SSL
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "6"
    tcp_options {
      min = 9092
      max = 9092
    }
  }

  # ICMP type 3 code 4 (Path MTU Discovery — "Destination Unreachable /
  # Fragmentation Needed"). Necessário para hosts atrás do NAT GW
  # negociarem MSS quando o caminho tem MTU menor.
  ingress_security_rules {
    source   = var.vcn_cidr
    protocol = "1"
    icmp_options {
      type = 3
      code = 4
    }
  }

  freeform_tags = local.common_tags
}

resource "oci_core_subnet" "public" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "uniplus-standalone-subnet-public"
  cidr_block                 = var.subnet_cidrs.public
  route_table_id             = oci_core_route_table.public.id
  security_list_ids          = [oci_core_security_list.public.id]
  prohibit_public_ip_on_vnic = false

  freeform_tags = local.common_tags
}

resource "oci_core_subnet" "private" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "uniplus-standalone-subnet-private"
  cidr_block                 = var.subnet_cidrs.private
  route_table_id             = oci_core_route_table.private.id
  security_list_ids          = [oci_core_security_list.private.id]
  prohibit_public_ip_on_vnic = true

  freeform_tags = local.common_tags
}
