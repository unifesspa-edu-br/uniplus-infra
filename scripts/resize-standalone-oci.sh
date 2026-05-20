#!/usr/bin/env bash
# ============================================================================
# resize-standalone-oci.sh
# Resize dos shapes (OCPU + memória) das 2 VMs do standalone OCI via
# `oci compute instance update --shape-config`.
#
# IMPORTANTE — Esta operação REBOOTA as VMs:
# `oci compute instance update --shape-config` é uma "Reshape" no OCI; quando
# o novo shape difere do atual em OCPU ou memória, a instância é reiniciada
# (~30-90s downtime por VM). Stateful services (Postgres/Kafka/Redis/MinIO/
# Vault) param e voltam ao subir o systemd; pods K8s entram em CrashLoop
# transitório enquanto k3s reaparece. NÃO rodar durante operação produtiva
# sem janela de manutenção planejada.
#
# Dito isso, em uso real (10/05) os 4 services systemd do data-host
# voltaram active sem perda de dados, e todos os pods do k8s-host
# religaram dentro de ~2min — graças à graceful shutdown do systemd e
# auto-recovery do k3s.
#
# Footprint padrão dimensionado para "validação de conceito" (sem load
# real): k8s-host roda k3s + ~20 pods leves; data-host roda Postgres + Kafka
# + Redis + MinIO em modo idle. Para HML/PROD escalar para shapes maiores.
#
# Uso:
#   ./scripts/resize-standalone-oci.sh                 # interativo, perfil poc
#   ./scripts/resize-standalone-oci.sh --profile=hml   # shapes maiores
#   ./scripts/resize-standalone-oci.sh --dry-run       # mostra plano sem aplicar
#   ./scripts/resize-standalone-oci.sh --yes           # pula confirmação (CI)
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
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile=*) PROFILE="${1#*=}";;
    --dry-run)   DRY_RUN=1;;
    --yes|-y)    ASSUME_YES=1;;
    -h|--help)   sed -n '2,40p' "$0"; exit 0;;
    *) echo "Opção desconhecida: $1" >&2; exit 1;;
  esac
  shift
done

# OCIDs das instâncias do standalone-compact (compartment root da tenancy unifesspa-edu-br).
# Ver: tofu -chdir=provisioning/oci/standalone-compact output k8s_host_ocid data_host_ocid
# ou:  oci compute instance list --compartment-id <tenancy-ocid> --query 'data[?contains("display-name", `compact`)].{name:"display-name",id:id}'
DATA_OCID="ocid1.instance.oc1.sa-saopaulo-1.antxeljr3d2ev6qcexcgjkod7ftc2pqo6u2kaywjwkciu2xokufardx46xeq"
K8S_OCID="ocid1.instance.oc1.sa-saopaulo-1.antxeljr3d2ev6qcwid3ytc2srjajyoyrgzpifyhhduhqufqdzbuqfcyrhta"

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

cat <<EOF
Perfil: $PROFILE
  k8s-host  → $K8S_OCPU OCPU / $K8S_MEM GB
  data-host → $DATA_OCPU OCPU / $DATA_MEM GB

ATENÇÃO: esta operação REBOOTA as 2 VMs (~30-90s downtime cada).
- Postgres, Kafka, Redis, MinIO, Vault: parados e religados pelo systemd
- Pods K8s: CrashLoop transitório enquanto k3s reaparece
- Não rode em produção sem janela de manutenção
EOF

if [ $DRY_RUN -eq 1 ]; then
  echo "[dry-run] nada aplicado."
  exit 0
fi

if [ $ASSUME_YES -eq 0 ]; then
  printf "Confirmar reboot e resize? [y/N] "
  read -r confirm
  case "$confirm" in
    y|Y|yes|YES) ;;
    *) echo "Abortado."; exit 1;;
  esac
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

cat <<EOF

Resize aplicado. Validar (após ~1-2min para serviços religarem):
  ssh ubuntu@137.131.131.6 'uptime; free -h | head -2; nproc'
  ssh ubuntu@137.131.131.6 'sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get nodes; sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get pods -A --field-selector=status.phase!=Running'
  ssh -J ubuntu@137.131.131.6 ubuntu@10.2.2.11 "uptime; systemctl is-active uniplus-postgres uniplus-kafka uniplus-redis uniplus-minio"
EOF
