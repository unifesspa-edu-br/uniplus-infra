variable "compartment_ocid" {
  description = "OCID do compartment onde os recursos vivem (no standalone, igual ao tenancy_ocid raiz)."
  type        = string
}

variable "region" {
  description = "Região OCI alvo (mesma do bootstrap inicial; mover de região exige recriação)."
  type        = string
  default     = "sa-saopaulo-1"
}

variable "availability_domain" {
  description = "Availability Domain das VMs e block volumes do standalone (single-AD por design)."
  type        = string
  default     = "mixQ:SA-SAOPAULO-1-AD-1"
}

variable "fault_domain" {
  description = "Fault Domain das VMs."
  type        = string
  default     = "FAULT-DOMAIN-1"
}

variable "vcn_cidr" {
  description = "CIDR block da VCN do standalone."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidrs" {
  description = "CIDR blocks das 2 subnets (public para k8s-host, private para data-host). Devem caber dentro de vcn_cidr."
  type = object({
    public  = string
    private = string
  })
  default = {
    public  = "10.0.1.0/24"
    private = "10.0.2.0/24"
  }
}

variable "image_ocid" {
  description = "OCID da imagem base (Ubuntu 24.04 LTS) — sa-saopaulo-1: ocid1.image.oc1.sa-saopaulo-1.aaaaaaaakoj2pbsggofw6sejgzfbyhv7ityl2cwomcslu47t3ncmmkwsp6ca."
  type        = string
}

variable "ssh_authorized_keys" {
  description = "Chaves SSH (uma por linha) injetadas via metadata em ambas instâncias."
  type        = string
}

variable "profile" {
  description = "Perfil de capacidade das VMs: 'poc' (~$72/mês compute) ou 'hml' (~$157/mês). Cada perfil mapeia para shape em locals.tf."
  type        = string
  default     = "poc"

  validation {
    condition     = contains(["poc", "hml"], var.profile)
    error_message = "profile deve ser 'poc' ou 'hml'."
  }
}

variable "volume_sizes_gbs" {
  description = "Tamanho em GB de cada block volume anexado ao data-host. Defaults preservam tamanhos vivos atuais; reduzir é destrutivo (delete+recreate) e perde dados."
  type = object({
    postgres = number
    kafka    = number
    minio    = number
    vault    = number
  })
  default = {
    postgres = 200
    kafka    = 100
    minio    = 200
    vault    = 50
  }
}

variable "volume_vpus_per_gb" {
  description = "VPUs por GB nos block volumes. 0 = Lower Cost (mínimo, sem IOPS dedicado); 10 = Balanced default OCI."
  type        = number
  default     = 0
}
