#!/usr/bin/env bash
# Primeiro sync de uma Application com Job de migration (PreSync), em dois tempos.
#
# O Job roda em PreSync, antes dos recursos da fase Sync, e consome a ServiceAccount
# e os Secrets que só nascem nela; num ambiente novo ele falharia por falta deles e o
# ArgoCD abortaria o sync antes de criar qualquer recurso. Este script faz o primeiro
# tempo: um sync completo, só desta operação, com o parâmetro que liga o Job
# (`uniplusApiHost.migrationJob.enabled`) em false. Sem o hook, a fase Sync cria a
# ServiceAccount, os ExternalSecrets e o restante; o schema é aplicado no boot do pod,
# correto num banco vazio. Depois o script espera os Secrets ficarem prontos. O
# segundo tempo é o sync normal, que já encontra tudo e executa o Job.
#
# A sobrescrita vale só para a operação (`operation.sync.sources`); o `spec` da
# Application e os values do ambiente não mudam.
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
# shellcheck source=lib-app.sh
source "$SCRIPT_DIR/lib-app.sh"

APP="uniplus-api-host"
NAMESPACE="uniplus"
ESPERA_SEGUNDOS=300
PARAMETRO_DO_JOB="uniplusApiHost.migrationJob.enabled"

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
APPLICATION="$APP"

# Monta o patch de operação: um sync completo das fontes da Application, com o Job de
# migration desligado só nesta operação.
montar_operacao() {
    kubectl -n argocd get application "$APPLICATION" -o json | python3 -c '
import json, sys
app = json.load(sys.stdin)
spec = app["spec"]
fontes = spec.get("sources")
if not fontes:
    sys.exit("A Application nao tem spec.sources; o script espera o formato multi-fonte do ApplicationSet.")
chart = next((f for f in fontes if f.get("path")), None)
if chart is None:
    sys.exit("Nenhuma fonte com path (chart) na Application.")
helm = chart.setdefault("helm", {})
parametros = [p for p in helm.get("parameters") or [] if p["name"] != sys.argv[1]]
parametros.append({"name": sys.argv[1], "value": "false"})
helm["parameters"] = parametros
print(json.dumps({"operation": {
    "initiatedBy": {"username": "primeiro-sync"},
    "sync": {
        "sources": fontes,
        "revisions": [f["targetRevision"] for f in fontes],
        "syncOptions": spec.get("syncPolicy", {}).get("syncOptions") or [],
    },
}}))' "$PARAMETRO_DO_JOB"
}

# Os ExternalSecrets que a Application declara (do estado dela no ArgoCD).
externalsecrets_da_application() {
    kubectl -n argocd get application "$APPLICATION" -o json | python3 -c '
import json, sys
for r in json.load(sys.stdin).get("status", {}).get("resources", []):
    if r["kind"] == "ExternalSecret":
        print(r["name"])'
}

# O patch só registra a operação; os ExternalSecrets passam a existir quando o
# ArgoCD a conclui.
esperar_operacao() {
    if ! kubectl -n argocd wait application "$APPLICATION" \
        --for=jsonpath='{.status.operationState.phase}'=Succeeded \
        --timeout="${ESPERA_SEGUNDOS}s"; then
        log_error "O primeiro sync de $APPLICATION não terminou com sucesso:"
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
    done < <(externalsecrets_da_application)
    if ((${#pendentes[@]} == 0)); then
        log_success "Todos os ExternalSecrets estão prontos."
        return 0
    fi
    log_error "ExternalSecrets que não ficaram prontos (falta segredo no Vault?):"
    printf '  %s\n' "${pendentes[@]}" >&2
    exit 1
}

if $DRY_RUN; then
    echo "[DRY-RUN] sync completo de $APPLICATION com $PARAMETRO_DO_JOB=false só nesta operação (sem o hook PreSync)"
    echo "[DRY-RUN] esperaria os ExternalSecrets de $NAMESPACE ficarem prontos ($ESPERA_SEGUNDOS s)"
    exit 0
fi
operacao=$(montar_operacao)
kubectl -n argocd patch application "$APPLICATION" --type merge -p "$operacao"
log_info "Primeiro sync de $APPLICATION iniciado (Job de migration desligado nesta operação)."
esperar_operacao
esperar_secrets
log_success "Primeiro tempo concluído."
log_info "Faça agora o sync normal de $APPLICATION: o Job de migration roda com a ServiceAccount e os Secrets já criados."
