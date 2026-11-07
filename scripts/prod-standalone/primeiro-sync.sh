#!/usr/bin/env bash
# Primeiro sync de uma Application com Job de migration (PreSync), em dois tempos.
#
# O Job roda antes dos demais recursos e consome a ServiceAccount e os Secrets que
# só nascem na fase Sync; num ambiente novo ele falharia por falta deles. Este
# script faz o primeiro tempo: sincroniza só a ServiceAccount e os ExternalSecrets
# da Application (sync seletivo não executa os hooks) e espera os Secrets ficarem
# prontos. O segundo tempo é o sync normal, que já encontra tudo e roda o Job.
#
# Uso:
#   ./primeiro-sync.sh [--app=uniplus-api-host] [--namespace=uniplus] [--dry-run]
#
# Rodar na VM de aplicação, depois de semear o Vault. Os ExternalSecrets que dependem
# de segredos de fora do repositório (clients do Keycloak, SMTP) só ficam prontos
# depois de gravados; o script lista os que não ficaram.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

APP="uniplus-api-host"
NAMESPACE="uniplus"
AMBIENTE="prod-standalone"
ESPERA_SEGUNDOS=300

mostrar_uso() {
    echo "Uso: $0 [--app=NOME] [--namespace=NS] [--dry-run]"
}

resto=()
for arg in "$@"; do
    case "$arg" in
        --app=*) APP="${arg#--app=}" ;;
        --namespace=*) NAMESPACE="${arg#--namespace=}" ;;
        *) resto+=("$arg") ;;
    esac
done
analisar_argumentos "${resto[@]}"
exigir_usuario_comum
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
APPLICATION="$APP-$AMBIENTE"

# Monta o patch de operação com a ServiceAccount e os ExternalSecrets da Application.
montar_operacao() {
    kubectl -n argocd get application "$APPLICATION" -o json | python3 -c '
import json, sys
app = json.load(sys.stdin)
recursos = [
    {"group": r.get("group", ""), "kind": r["kind"], "name": r["name"], "namespace": r.get("namespace", "")}
    for r in app.get("status", {}).get("resources", [])
    if r["kind"] in ("ServiceAccount", "ExternalSecret")
]
if not recursos:
    sys.exit("A Application não lista ServiceAccount nem ExternalSecret; faça o refresh no ArgoCD.")
print(json.dumps({"operation": {
    "initiatedBy": {"username": "primeiro-sync"},
    "sync": {"resources": recursos, "syncOptions": ["ServerSideApply=true"]},
}}))'
}

externalsecrets_da_operacao() {
    python3 -c '
import json, sys
for r in json.loads(sys.argv[1])["operation"]["sync"]["resources"]:
    if r["kind"] == "ExternalSecret":
        print(r["name"])' "$1"
}

# O patch só registra a operação; os ExternalSecrets passam a existir quando o
# ArgoCD a conclui. Esperar por nome evita aceitar um conjunto parcial.
esperar_operacao() {
    if ! kubectl -n argocd wait application "$APPLICATION" \
        --for=jsonpath='{.status.operationState.phase}'=Succeeded \
        --timeout="${ESPERA_SEGUNDOS}s"; then
        log_error "O sync seletivo de $APPLICATION não terminou com sucesso:"
        kubectl -n argocd get application "$APPLICATION" \
            -o jsonpath='{.status.operationState.message}{"\n"}' >&2
        exit 1
    fi
}

esperar_secrets() {
    local nome pendentes=()
    while read -r nome; do
        [[ -z "$nome" ]] && continue
        if ! kubectl -n "$NAMESPACE" wait --for=condition=Ready "externalsecret/$nome" \
            --timeout="${ESPERA_SEGUNDOS}s" >/dev/null 2>&1; then
            pendentes+=("$nome")
        fi
    done < <(externalsecrets_da_operacao "$1")
    if ((${#pendentes[@]} == 0)); then
        log_success "Todos os ExternalSecrets estão prontos."
        return 0
    fi
    log_error "ExternalSecrets que não ficaram prontos (falta segredo no Vault?):"
    printf '  %s\n' "${pendentes[@]}" >&2
    exit 1
}

if $DRY_RUN; then
    echo "[DRY-RUN] sync seletivo de ServiceAccount e ExternalSecret em $APPLICATION (sem hooks)"
    echo "[DRY-RUN] esperaria os ExternalSecrets de $NAMESPACE ficarem prontos ($ESPERA_SEGUNDOS s)"
    exit 0
fi
operacao=$(montar_operacao)
kubectl -n argocd patch application "$APPLICATION" --type merge -p "$operacao"
log_info "Sync seletivo de $APPLICATION iniciado."
esperar_operacao
esperar_secrets "$operacao"
log_success "Primeiro tempo concluído. Faça agora o sync normal de $APPLICATION (roda o Job de migration)."
