#!/usr/bin/env bash
# Primeiro sync de uma Application com Job de migration (PreSync), em dois tempos.
#
# O Job roda antes dos demais recursos e consome a ServiceAccount e os Secrets que
# só nascem na fase Sync; num ambiente novo ele falharia por falta deles. Este
# script faz o primeiro tempo: sincroniza só a ServiceAccount e os ExternalSecrets
# da Application e espera os Secrets ficarem prontos. O sync seletivo também
# executa o hook PreSync (observado em produção), então o Job de migration pode
# rodar já neste tempo; se falhar por falta de Secret, o segundo tempo (sync
# normal) repete o Job com os Secrets já criados.
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
APPLICATION="$APP-$NOME_DO_CLUSTER"

# Monta o patch de operação com a ServiceAccount e os ExternalSecrets da Application.
montar_operacao() {
    kubectl -n argocd get application "$APPLICATION" -o json | python3 -c '
import json, sys
app = json.load(sys.stdin)
# syncOptions da operação substitui as do spec; repete-as e acrescenta SSA.
opcoes = list(app.get("spec", {}).get("syncPolicy", {}).get("syncOptions") or [])
if "ServerSideApply=true" not in opcoes:
    opcoes.append("ServerSideApply=true")
recursos = [
    {"group": r.get("group", ""), "kind": r["kind"], "name": r["name"], "namespace": r.get("namespace", "")}
    for r in app.get("status", {}).get("resources", [])
    if r["kind"] in ("ServiceAccount", "ExternalSecret")
]
if not recursos:
    sys.exit("A Application não lista ServiceAccount nem ExternalSecret; faça o refresh no ArgoCD.")
print(json.dumps({"operation": {
    "initiatedBy": {"username": "primeiro-sync"},
    "sync": {"resources": recursos, "syncOptions": opcoes},
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
    echo "[DRY-RUN] sync seletivo de ServiceAccount e ExternalSecret em $APPLICATION (o hook PreSync também roda)"
    echo "[DRY-RUN] esperaria os ExternalSecrets de $NAMESPACE ficarem prontos ($ESPERA_SEGUNDOS s)"
    exit 0
fi
operacao=$(montar_operacao)
kubectl -n argocd patch application "$APPLICATION" --type merge -p "$operacao"
log_info "Sync seletivo de $APPLICATION iniciado."
esperar_operacao
esperar_secrets "$operacao"
log_success "Primeiro tempo concluído."
log_info "O sync seletivo executa o hook PreSync: o Job de migration pode já ter rodado."
log_info "Faça agora o sync normal de $APPLICATION. Se o Job tiver falhado por falta de Secret, esse sync o executa de novo."
