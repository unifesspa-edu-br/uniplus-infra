# ==============================================================================
# Network do standalone-compact
#
# Topologia diferente do `standalone/`:
#   - 2 subnets PÚBLICAS (uma por host) — SLs por subnet (OCI SL é subnet-scoped)
#   - SEM NAT Gateway (item mais caro do lab atual, ~$33/mês)
#   - data-host com public IP efêmero — egress via IGW direto
#   - Subnet do data-host com SL restritiva: ingress só do VCN CIDR
#
#                ┌────────────────────────┐
#                │  Internet              │
#                └────────────┬───────────┘
#                             │
#                  ┌──────────▼──────────┐
#                  │  IGW (Always Free)  │
#                  └──────────┬──────────┘
#                             │
#                ┌────────────▼────────────────────────┐
#                │  VCN  10.2.0.0/16                   │
#                │                                     │
#                │  Subnet public-k8s 10.2.1.0/24      │
#                │  ┌──────────────────┐               │
#                │  │ k8s-host         │ ← SL_K        │
#                │  │ A1 2OCPU/12GB    │   22/80/443   │
#                │  │ Reserved Pub IP  │   from 0/0    │
#                │  └────────┬─────────┘               │
#                │           │ 22/Postgres/Kafka/...   │
#                │           ▼                         │
#                │  Subnet public-data 10.2.2.0/24     │
#                │  ┌──────────────────┐               │
#                │  │ data-host        │ ← SL_D        │
#                │  │ A1 2OCPU/12GB    │   22/5432/    │
#                │  │ Ephemeral Pub IP │   9092/...    │
#                │  │ + 100 GB block   │   from VCN    │
#                │  └──────────────────┘               │
#                └─────────────────────────────────────┘
#
# Por que 2 subnets em vez de uma?
#   SL é subnet-scoped na OCI. Para o data-host receber só do k8s-host (e não
#   da internet) enquanto o k8s-host aceita HTTP/HTTPS do mundo, precisamos
#   de SLs separadas. NSG (VNIC-scoped) seria alternativa moderna, mas
#   manter alinhado com o pattern do `standalone/` (que usa SLs).
# ==============================================================================

resource "oci_core_vcn" "this" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "uniplus-compact-vcn"
  dns_label      = "compact"

  freeform_tags = local.common_tags
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-compact-igw"
  enabled        = true

  freeform_tags = local.common_tags
}

resource "oci_core_route_table" "main" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-compact-rt"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }

  freeform_tags = local.common_tags
}

# ------------------------------------------------------------------------------
# Security List do k8s-host — exposto a internet (HTTP/HTTPS/SSH)
# ------------------------------------------------------------------------------
resource "oci_core_security_list" "k8s_host" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-compact-sl-k8s-host"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6" # TCP
    description = "SSH"
    tcp_options {
      min = 22
      max = 22
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    description = "HTTP (Traefik / cert-manager HTTP-01)"
    tcp_options {
      min = 80
      max = 80
    }
  }

  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "6"
    description = "HTTPS (Traefik)"
    tcp_options {
      min = 443
      max = 443
    }
  }

  # Path MTU Discovery: ICMP type 3 code 4 vem de roteadores no path da
  # internet (IPs públicos arbitrários fora do CIDR). Restringir ao VCN
  # CIDR quebraria conexões com paths low-MTU (VPN, IPsec, alguns cabos).
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "1" # ICMP
    description = "Path MTU Discovery (ICMP type 3 code 4) from internet routers"
    icmp_options {
      type = 3
      code = 4
    }
  }

  freeform_tags = local.common_tags
}

# ------------------------------------------------------------------------------
# Security List do data-host — APENAS hosts dentro da VCN (k8s-host) acessam
#
# data-host fica em subnet PÚBLICA com IP efêmero (sem NAT). Sem essa SL
# restritiva, a internet inteira poderia tentar conexões nos serviços
# (Postgres, Kafka, MinIO). Aqui só aceita do CIDR da VCN. PMTUD ICMP do
# 0.0.0.0/0 (necessário para egress healthy em paths low-MTU).
# ------------------------------------------------------------------------------
resource "oci_core_security_list" "data_host" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.this.id
  display_name   = "uniplus-compact-sl-data-host"

  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH via jump-host (k8s-host)
  ingress_security_rules {
    source      = var.vcn_cidr
    protocol    = "6"
    description = "SSH from VCN only (jump through k8s-host)"
    tcp_options {
      min = 22
      max = 22
    }
  }

  # PostgreSQL
  ingress_security_rules {
    source      = var.vcn_cidr
    protocol    = "6"
    description = "PostgreSQL"
    tcp_options {
      min = 5432
      max = 5432
    }
  }

  # Redis
  ingress_security_rules {
    source      = var.vcn_cidr
    protocol    = "6"
    description = "Redis"
    tcp_options {
      min = 6379
      max = 6379
    }
  }

  # MinIO API + console
  ingress_security_rules {
    source      = var.vcn_cidr
    protocol    = "6"
    description = "MinIO API and Console"
    tcp_options {
      min = 9000
      max = 9001
    }
  }

  # Kafka SASL_SSL
  ingress_security_rules {
    source      = var.vcn_cidr
    protocol    = "6"
    description = "Kafka SASL_SSL"
    tcp_options {
      min = 9092
      max = 9092
    }
  }

  # Prometheus node-exporter (scrape from k8s-host)
  ingress_security_rules {
    source      = var.vcn_cidr
    protocol    = "6"
    description = "Prometheus node-exporter scrape"
    tcp_options {
      min = 9100
      max = 9100
    }
  }

  # Path MTU Discovery
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "1"
    description = "Path MTU Discovery (ICMP type 3 code 4) from internet routers"
    icmp_options {
      type = 3
      code = 4
    }
  }

  freeform_tags = local.common_tags
}

resource "oci_core_subnet" "k8s_host" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "uniplus-compact-subnet-k8s-host"
  cidr_block                 = "10.2.1.0/24"
  route_table_id             = oci_core_route_table.main.id
  prohibit_public_ip_on_vnic = false
  dns_label                  = "k8s"
  security_list_ids          = [oci_core_security_list.k8s_host.id]

  freeform_tags = local.common_tags
}

resource "oci_core_subnet" "data_host" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.this.id
  display_name               = "uniplus-compact-subnet-data-host"
  cidr_block                 = "10.2.2.0/24"
  route_table_id             = oci_core_route_table.main.id
  prohibit_public_ip_on_vnic = false
  dns_label                  = "data"
  security_list_ids          = [oci_core_security_list.data_host.id]

  freeform_tags = local.common_tags
}
