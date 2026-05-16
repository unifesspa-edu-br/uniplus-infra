variable "compartment_ocid" {
  description = "OCID do compartment onde os recursos vivem (no iad-arm POC, igual ao tenancy_ocid raiz)."
  type        = string
}

variable "region" {
  description = "Região OCI alvo. iad-arm é fixado em us-ashburn-1 (IAD) — maior capacidade A1 ARM histórica nos EUA e menor latência do Brasil entre as regiões PAYG-disponíveis."
  type        = string
  default     = "us-ashburn-1"
}

variable "availability_domain" {
  description = "Availability Domain das VMs e block volumes em IAD. IAD tem 3 ADs; default escolhe a primeira. Substituir pelo valor real após Story #319/T1.1.2 (`oci iam availability-domain list --region us-ashburn-1`)."
  type        = string
  default     = "REPLACE_AFTER_T1_1_2"
}

variable "fault_domain" {
  description = "Fault Domain das VMs."
  type        = string
  default     = "FAULT-DOMAIN-1"
}

variable "vcn_cidr" {
  description = "CIDR block da VCN. iad-arm usa 10.1.0.0/16 (não 10.0.0.0/16 do `standalone`) para evitar conflito quando ambos os labs coexistirem durante a janela de migração."
  type        = string
  default     = "10.1.0.0/16"
}

variable "subnet_cidrs" {
  description = "CIDR blocks das 2 subnets (public para k8s-host, private para data-host). Devem caber dentro de vcn_cidr."
  type = object({
    public  = string
    private = string
  })
  default = {
    public  = "10.1.1.0/24"
    private = "10.1.2.0/24"
  }
}

variable "image_ocid" {
  description = "OCID da imagem base Ubuntu 24.04 LTS aarch64 em us-ashburn-1. Substituir após Story #319/T1.1.2 (`oci compute image list --region us-ashburn-1 --shape VM.Standard.A1.Flex --operating-system 'Canonical Ubuntu' --operating-system-version 24.04 --sort-by TIMECREATED --sort-order DESC`)."
  type        = string
  default     = "REPLACE_AFTER_T1_1_2"
}

# Nota: o nome da zona DNS pública (`portaluni.com.br`) é hardcoded em
# dns.tf via data source porque é compartilhado entre ambientes da plataforma.
# iad-arm cria registros sob o subdomínio `iad-arm.portaluni.com.br` enquanto
# `standalone.portaluni.com.br` continua apontando para o lab GRU; o cutover
# DNS final (Story #359) reaponta o domínio canônico (definir na Story) para
# os IPs IAD e destrói o lab GRU.

variable "ssh_authorized_keys" {
  description = "Chaves SSH (uma por linha) injetadas via metadata em ambas instâncias."
  type        = string
}

variable "profile" {
  description = "Perfil de capacidade das VMs A1.Flex. 'poc_arm' (default) = 3 OCPU / 16 GB total, cabe em Always Free A1 (4 OCPU / 24 GB). 'hml_arm' = 6 OCPU / 40 GB total — EXTRAPOLA Always Free, cobra ~$25/mês. Mapeamento em locals.tf."
  type        = string
  default     = "poc_arm"

  validation {
    condition     = contains(["poc_arm", "hml_arm"], var.profile)
    error_message = "profile deve ser 'poc_arm' ou 'hml_arm' (perfis A1.Flex)."
  }
}

variable "volume_sizes_gbs" {
  description = "Tamanho em GB de cada block volume anexado ao data-host. Defaults somam 200 GB exatos (limite Always Free OCI Block Volume). Aumentar passa a cobrar ~$0.0085/GB-extra/mês."
  type = object({
    postgres = number
    kafka    = number
    minio    = number
    vault    = number
  })
  default = {
    postgres = 80
    kafka    = 40
    minio    = 60
    vault    = 20
  }
}

variable "volume_vpus_per_gb" {
  description = "VPUs por GB nos block volumes. 0 = Lower Cost (mínimo, sem IOPS dedicado); 10 = Balanced default OCI. iad-arm usa 0 (suficiente para POC e mantém custo em zero dentro do Always Free)."
  type        = number
  default     = 0
}
