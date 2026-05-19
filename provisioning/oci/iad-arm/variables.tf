variable "compartment_ocid" {
  description = "OCID do compartment onde os recursos vivem (no iad-arm POC, igual ao tenancy_ocid raiz)."
  type        = string
}

variable "tenancy_ocid" {
  description = "OCID da tenancy (compartment raiz). Necessário separadamente de `compartment_ocid` porque IAM Dynamic Groups e Policies tenancy-scoped DEVEM residir no compartment raiz, independente do compartment onde compute/network vivem. No iad-arm POC esse valor é igual a `compartment_ocid` (tudo na raiz); em ambientes com isolamento por compartment, manter este aqui apontando para o root e `compartment_ocid` para o child."
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
  description = "Tamanho em GB de cada block volume anexado ao data-host. OCI rejeita volumes <50 GB no `CreateVolume` (mínimo documentado: 50 GB, máximo 32 TB, incrementos de 1 GB). Defaults distribuem 4×50 GB = 200 GB total — bate exato no teto histórico da decisão binding do Epic #317. ATENÇÃO: o Always Free Block Volume (200 GB) é amarrado à HOME REGION da tenancy (GRU, no caso da unifesspa-edu-br); volumes em IAD são cobrados em PAYG a ~$0.0255/GB-mês (VPU 0). Custo estimado em IAD: 4×50 GB = ~$5.10/mês. **DEPENDÊNCIA**: `scripts/bootstrap-standalone.sh` hoje identifica papéis dos block volumes por tamanho (45-55 → vault; 95-105 → kafka; 190-210 → postgres+minio). Com 4×50 GB todos os disks colidem na faixa do vault, e o bootstrap aborta na função `discover_disks`. A refatoração para identificação por display_name/LUN/OCI metadata é PRÉ-REQUISITO da Story #329 (apply em IAD) e está rastreada como follow-up do Epic #317 (ver thread Codex em PR #374)."
  type = object({
    postgres = number
    kafka    = number
    minio    = number
    vault    = number
  })
  default = {
    postgres = 50
    kafka    = 50
    minio    = 50
    vault    = 50
  }
}

variable "volume_vpus_per_gb" {
  description = "VPUs por GB nos block volumes. 0 = Lower Cost (mínimo, sem IOPS dedicado, $0.0255/GB-mês PAYG); 10 = Balanced default OCI ($0.0425/GB-mês PAYG). iad-arm usa 0 (suficiente para POC e minimiza custo já que IAD não tem Always Free Block Volume — home region = GRU)."
  type        = number
  default     = 0
}
