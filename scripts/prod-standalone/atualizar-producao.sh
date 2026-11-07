#!/usr/bin/env bash
# Atualiza a produção para uma tag de uma vez: confere que o checkout está nela,
# grava a revisão no cluster do ArgoCD e reaplica os ApplicationSets e o
# verificador. Não sincroniza nada: depois dele, cada Application mostra o que
# mudou e é sincronizada à mão (UI ou `argocd app sync`), na ordem do runbook.
#
# Uso:
#   ./atualizar-producao.sh --revisao=vX.Y.Z [--dry-run]
#
# A tag precisa ter sido validada em homologação. Rodar na VM de aplicação.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-app.sh
source "$SCRIPT_DIR/lib-app.sh"

REVISAO=""

mostrar_uso() {
    echo "Uso: $0 --revisao=vX.Y.Z [--dry-run]"
}

resto=()
for arg in "$@"; do
    case "$arg" in
        --revisao=*) REVISAO="${arg#--revisao=}" ;;
        *) resto+=("$arg") ;;
    esac
done
analisar_argumentos "${resto[@]}"
[[ -n "$REVISAO" ]] || { mostrar_uso >&2; exit 2; }

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
validar_revisao "$REVISAO"
registrar_cluster "$REVISAO"
aplicar_argocd "$REVISAO"
log_success "Revisão $REVISAO registrada. Sincronize cada Application à mão, na ordem do runbook."
