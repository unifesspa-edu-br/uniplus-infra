variable "compartment_ocid" {
  description = "OCID do compartment onde os recursos vivem (no compact POC, igual ao tenancy_ocid raiz)."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID da tenancy (compartment raiz). IAM Dynamic Groups e Policies tenancy-scoped DEVEM residir no compartment raiz, independente do compartment escolhido para compute/network. No compact POC ambos apontam para o mesmo OCID (tenancy raiz)."
  type        = string
}

variable "region" {
  description = "Região OCI alvo. compact é fixado em sa-saopaulo-1 (GRU) — a home region da tenancy unifesspa-edu-br. Manter em home garante: (1) Always Free Block Volume (200 GB) válida; (2) IAM master ops funcionam sem provider alias. O compute usa E4.Flex AMD PAYG (A1 Always Free não disponível em GRU nesta tenancy)."
  type        = string
  default     = "sa-saopaulo-1"
}

variable "availability_domain" {
  description = "Availability Domain de GRU. sa-saopaulo-1 tem 1 AD; default é o único disponível."
  type        = string
  default     = "mixQ:SA-SAOPAULO-1-AD-1"
}

variable "fault_domain" {
  description = "Fault Domain das VMs."
  type        = string
  default     = "FAULT-DOMAIN-1"
}

variable "vcn_cidr" {
  description = "CIDR block da VCN. compact usa 10.2.0.0/16 (o legado standalone, já removido, usava 10.0.0.0/16). O bootstrap-standalone.sh deriva as regras de firewall deste CIDR."
  type        = string
  default     = "10.2.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR base das subnets públicas. compact usa subnets públicas (k8s 10.2.1.0/24 + data 10.2.2.0/24) para eliminar a necessidade de NAT Gateway. O data-host ganha public IP efêmero (egress) e a Security List restritiva controla o ingress."
  type        = string
  default     = "10.2.1.0/24"
}

variable "image_ocid" {
  description = "OCID da imagem base Ubuntu 24.04 LTS x86_64 em sa-saopaulo-1 (compatível com E4.Flex AMD). Descobrir via: oci compute image list --region sa-saopaulo-1 --operating-system 'Canonical Ubuntu' --operating-system-version 24.04 --shape VM.Standard.E4.Flex --sort-by TIMECREATED --sort-order DESC --query 'data[0].id' --raw-output"
  type        = string
}

variable "ssh_authorized_keys" {
  description = "Chaves SSH (uma por linha) injetadas via metadata em ambas instâncias."
  type        = string
}

variable "volume_size_gbs" {
  description = "Tamanho do block volume único do data-host. Always Free Block Volume é 200 GB total em home region; 2 boot volumes consomem 94 GB (47 cada), então o block pode ir até 106 GB sem sair do free tier. Default 100 GB deixa folga de 6 GB. Mínimo OCI é 50 GB."
  type        = number
  default     = 100

  validation {
    # Mínimo 95 GB: setup_lvm_compact() em bootstrap-standalone.sh cria LVs
    # fixos somando 95 GB (postgres 30 + kafka 20 + minio 40 + vault 5). Abaixo
    # disso o tofu apply passa mas o bootstrap falha no lvcreate. Teto 200 GB
    # mantém boot+block dentro do Always Free Block Volume da home region.
    condition     = var.volume_size_gbs >= 95 && var.volume_size_gbs <= 32000
    error_message = "volume_size_gbs deve estar entre 95 (mínimo para os LVs do data-host) e 32000 (limite OCI)."
  }
}

variable "volume_vpus_per_gb" {
  description = "VPUs por GB nos block volumes. 0 = Lower Cost (mínimo, sem IOPS dedicado). Always Free Block Volume só vale para VPU 0 — qualquer valor >0 sai do free tier."
  type        = number
  default     = 0

  validation {
    condition     = var.volume_vpus_per_gb == 0
    error_message = "volume_vpus_per_gb deve ser 0 para preservar Always Free Block Volume. Use 10 (Balanced) ou superior só se aceitar PAYG."
  }
}
