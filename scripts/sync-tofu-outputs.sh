#!/usr/bin/env bash
# ============================================================================
# sync-tofu-outputs.sh
# Bridge entre `tofu output` (provisioning/oci/standalone-compact/) e os values
# dos charts Helm consumidos via ArgoCD. Story #58 da Feature #43.
#
# Estratégia (compatível com GitOps):
# - Schema do `environments/standalone-compact/values.yaml` continua
#   provider-agnostic (versionado em git, lido pelo ArgoCD).
# - Valores OCI-specific (IPs, hostnames) ficam **hardcoded** no values.yaml
#   pra ArgoCD ter tudo no repo. Recreate de infra que mude algum desses
#   valores exige PR ajustando o values.yaml — esse script ajuda a detectar
#   o drift e (opcionalmente) materializar via ConfigMap K8s.
# - Outputs sensíveis ou privados (OCIDs do Vault/KMS, secrets gerados pelo
#   provisioning) NÃO entram em values.yaml. Vão num ConfigMap (não-secret)
#   ou Secret no namespace `uniplus`, populado por este script — charts os
#   consomem via envFrom/valueFrom.
#
# Uso:
#   ./scripts/sync-tofu-outputs.sh                  # imprime tabela
#   ./scripts/sync-tofu-outputs.sh --diff           # compara outputs vs values.yaml
#   ./scripts/sync-tofu-outputs.sh --apply-configmap [--namespace=uniplus]
#                                                    # cria/patcha ConfigMap K8s
#   ./scripts/sync-tofu-outputs.sh --json           # imprime JSON cru
#
# Pré-requisitos:
#   - tofu state inicializado em provisioning/oci/standalone-compact (ou seja:
#     `cd provisioning/oci/standalone-compact && tofu init`, conforme README
#     do diretório)
#   - kubectl configurado para o cluster alvo (apenas para --apply-configmap)
# ============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOFU_DIR="${REPO_ROOT}/provisioning/oci/standalone-compact"
ENV_VALUES="${REPO_ROOT}/environments/standalone-compact/values.yaml"
NAMESPACE="uniplus"
CONFIGMAP_NAME="standalone-tofu-outputs"

MODE="table"
while [ $# -gt 0 ]; do
  case "$1" in
    --diff)             MODE="diff" ;;
    --apply-configmap)  MODE="apply-configmap" ;;
    --json)             MODE="json" ;;
    --namespace=*)      NAMESPACE="${1#*=}" ;;
    -h|--help)          sed -n '2,30p' "$0"; exit 0 ;;
    *)                  echo "Opção desconhecida: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ ! -d "${TOFU_DIR}/.terraform" ]; then
  echo "Erro: ${TOFU_DIR}/.terraform/ não existe — rodar 'tofu init' antes." >&2
  echo "Ver ${TOFU_DIR}/README.md §Setup." >&2
  exit 2
fi

# Pega outputs como JSON
OUTPUTS_JSON=$(cd "${TOFU_DIR}" && tofu output -json 2>/dev/null || true)
if [ -z "${OUTPUTS_JSON}" ] || [ "${OUTPUTS_JSON}" = "{}" ]; then
  echo "Erro: nenhum output Tofu encontrado em ${TOFU_DIR}." >&2
  echo "Verificar se 'tofu apply' foi executado e state está populado." >&2
  exit 3
fi

case "${MODE}" in
  json)
    echo "${OUTPUTS_JSON}"
    ;;

  table)
    echo "Outputs Tofu de ${TOFU_DIR}:"
    echo "${OUTPUTS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key, info in sorted(data.items()):
    val = info.get('value')
    if isinstance(val, dict):
        val = json.dumps(val, separators=(',', ':'))
    sensitive = ' [SENSITIVE]' if info.get('sensitive') else ''
    print(f'  {key:30s} = {val}{sensitive}')
"
    echo
    echo "Mapeamento para environments/standalone-compact/values.yaml:"
    cat <<MAP
  k8s_host_public_ip         → standalone.<ingress.host>; uniplusKafkaUi/oidcIssuerCIDR (deriva /32)
  data_host_private_ip       → uniplusKeycloak.db.host
                               kafkaUi.kafka.bootstrapServers (porta 9092)
                               apicurioRegistry.db.host
                               redisUi.redis.host
                               minioConsole.minio.host
                               uniplusApi*.db.host
                               keycloakReplica.networkPolicy.dataHostCIDR (deriva /32)
  dns_apex_fqdn              → ingress.host (apex e CNAMEs derivados)
  vcn_ocid + subnet_*_ocid   → não consumidos pelos charts hoje; expostos
                               para infra paralela (HML separado etc.).
  kms_key_ocid               → seal "ocikms".key_id (chart platform/vault)
  kms_management_endpoint    → seal "ocikms".management_endpoint
  kms_crypto_endpoint        → seal "ocikms".crypto_endpoint
  kms_vault_ocid             → comentário/auditoria (chart referencia só a key)
  kms_dynamic_group_ocid     → idem
  kms_policy_ocid            → idem
MAP
    ;;

  diff)
    echo "Comparando outputs Tofu com ${ENV_VALUES}:"
    K8S_IP=$(echo "${OUTPUTS_JSON}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('k8s_host_public_ip',{}).get('value',''))")
    DATA_IP=$(echo "${OUTPUTS_JSON}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('data_host_private_ip',{}).get('value',''))")
    DNS_FQDN=$(echo "${OUTPUTS_JSON}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('dns_apex_fqdn',{}).get('value',''))")

    check_value() {
      local label="$1" expected="$2" file="$3"
      if grep -qF "${expected}" "${file}"; then
        echo "  [OK]   ${label} = ${expected}"
      else
        echo "  [DRIFT] ${label} = ${expected} NÃO encontrado em ${file##*/}"
      fi
    }

    [ -n "${K8S_IP}" ]   && check_value "k8s_host_public_ip"   "${K8S_IP}"   "${ENV_VALUES}"
    [ -n "${DATA_IP}" ]  && check_value "data_host_private_ip" "${DATA_IP}"  "${ENV_VALUES}"
    [ -n "${DNS_FQDN}" ] && check_value "dns_apex_fqdn"         "${DNS_FQDN}" "${ENV_VALUES}"
    ;;

  apply-configmap)
    if ! command -v kubectl >/dev/null 2>&1; then
      echo "Erro: kubectl não encontrado no PATH." >&2
      exit 4
    fi
    echo "Criando/atualizando ConfigMap '${CONFIGMAP_NAME}' em namespace '${NAMESPACE}'..."

    # Extrai cada output como uma chave plana no ConfigMap (string).
    declare -a kcm_args=()
    while IFS=$'\t' read -r key val; do
      [ -n "${val}" ] && kcm_args+=("--from-literal=${key}=${val}")
    done < <(echo "${OUTPUTS_JSON}" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for key, info in sorted(data.items()):
    val = info.get('value')
    if isinstance(val, (dict, list)):
        val = json.dumps(val, separators=(',', ':'))
    if val is None:
        continue
    print(f'{key}\t{val}')
")

    # kubectl create + dry-run + apply para idempotência (cria ou patcha)
    kubectl create configmap "${CONFIGMAP_NAME}" \
      --namespace="${NAMESPACE}" \
      "${kcm_args[@]}" \
      --dry-run=client -o yaml | kubectl apply -f -

    echo
    echo "ConfigMap aplicado. Charts podem consumir via:"
    echo "  envFrom: [{ configMapRef: { name: ${CONFIGMAP_NAME} } }]"
    echo "  valueFrom: { configMapKeyRef: { name: ${CONFIGMAP_NAME}, key: <output-name> } }"
    ;;
esac
