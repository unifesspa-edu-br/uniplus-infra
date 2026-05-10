#!/usr/bin/env bash
# ============================================================================
# resize-standalone-oci.sh
# Hot-resize dos shapes (OCPU + memória) das 2 VMs do standalone OCI.
# E5.Flex permite reconfiguração online sem reboot — operação reversível,
# zero downtime no compute.
#
# Footprint padrão é dimensionado para "validação de conceito" (sem load
# real): k8s-host roda k3s + ~20 pods leves; data-host roda Postgres + Kafka
# + Redis + MinIO em modo idle. Para HML/PROD escalar para shapes maiores.
#
# Uso:
#   ./scripts/resize-standalone-oci.sh                 # aplica perfil "min"
#   ./scripts/resize-standalone-oci.sh --profile=poc   # idem
#   ./scripts/resize-standalone-oci.sh --profile=hml   # shapes mais robustos
#   ./scripts/resize-standalone-oci.sh --dry-run       # mostra plano sem aplicar
#
# Pré-requisitos:
#   - oci CLI configurada (~/.oci/config) com permissão para
#     COMPUTE_INSTANCE_INSPECT + UPDATE no compartment do standalone
#   - Variável TENANCY ou ~/.oci/config com tenancy default
#
# Custo (sa-saopaulo-1, E5.Flex pay-as-you-go, ~730h/mês):
#   - 1 OCPU + 4 GB  = $0.031/h ≈ $22.63/mês
#   - 1 OCPU + 8 GB  = $0.037/h ≈ $27.01/mês
#   - 2 OCPU + 12 GB = $0.068/h ≈ $49.64/mês
#   - 4 OCPU + 32 GB = $0.148/h ≈ $108.04/mês  (shape original)
# ============================================================================

set -euo pipefail

PROFILE="poc"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile=*) PROFILE="${1#*=}";;
    --dry-run)   DRY_RUN=1;;
    -h|--help)   sed -n '2,30p' "$0"; exit 0;;
    *) echo "Opção desconhecida: $1" >&2; exit 1;;
  esac
  shift
done

# OCIDs das instâncias do standalone (compartment root da tenancy unifesspa-edu-br).
# Ver: oci compute instance list --compartment-id <tenancy-ocid> --query 'data[?contains("display-name", `standalone`)].{name:"display-name",id:id}'
DATA_OCID="ocid1.instance.oc1.sa-saopaulo-1.antxeljr3d2ev6qcmjvq4kk7oheaut5hzo7v6xgfj2kasku5kbs6vro5o26q"
K8S_OCID="ocid1.instance.oc1.sa-saopaulo-1.antxeljr3d2ev6qc2675teq7fatuqdgn37sj45fbip24iycfmkowa4ye7z5a"

case "$PROFILE" in
  poc)
    K8S_OCPU=2;  K8S_MEM=12
    DATA_OCPU=1; DATA_MEM=4
    ;;
  hml)
    K8S_OCPU=4;  K8S_MEM=24
    DATA_OCPU=2; DATA_MEM=16
    ;;
  *) echo "Perfil desconhecido: $PROFILE (use poc|hml)" >&2; exit 1;;
esac

echo "Perfil: $PROFILE"
echo "  k8s-host  → $K8S_OCPU OCPU / $K8S_MEM GB"
echo "  data-host → $DATA_OCPU OCPU / $DATA_MEM GB"
echo

if [ $DRY_RUN -eq 1 ]; then
  echo "[dry-run] nada aplicado."
  exit 0
fi

resize() {
  local label="$1" ocid="$2" ocpu="$3" mem="$4"
  echo "==> $label ($ocpu OCPU / $mem GB):"
  oci compute instance update \
    --instance-id "$ocid" \
    --shape-config "{\"ocpus\":$ocpu,\"memoryInGBs\":$mem}" \
    --force \
    --wait-for-state RUNNING \
    --query 'data."shape-config".{ocpus:ocpus,mem:"memory-in-gbs"}'
}

resize "data-host" "$DATA_OCID" "$DATA_OCPU" "$DATA_MEM"
resize "k8s-host"  "$K8S_OCID"  "$K8S_OCPU"  "$K8S_MEM"

echo
echo "Resize aplicado. Validar com:"
echo "  ssh ubuntu@164.152.53.29 'free -h | head -2; nproc'"
echo "  ssh ubuntu@164.152.53.29 'sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl top node'"
echo "  ssh ubuntu@164.152.53.29 'ssh ubuntu@10.0.2.87 \"systemctl is-active uniplus-postgres uniplus-kafka uniplus-redis uniplus-minio\"'"
