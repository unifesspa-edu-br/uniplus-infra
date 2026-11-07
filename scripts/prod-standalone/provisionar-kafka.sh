#!/usr/bin/env bash
# Provisiona o Kafka de produção para o registro de acesso: tópico, usuário SCRAM
# com ACL de escrita, a senha dele e o CA do broker no Vault. Reaproveita o script
# de homologação, com o broker alcançado pelo FQDN da VM de infraestrutura (o
# certificado é validado pelo nome).
#
# Uso: [VAULT_URL=...] ./provisionar-kafka.sh [--dry-run] [provisionar|ca|verificar]
# Rodar na VM de infraestrutura, depois de semear-vault.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

mostrar_uso() {
    echo "Uso: $0 [--dry-run] [provisionar|ca|verificar]"
}

acao=()
resto=()
for arg in "$@"; do
    case "$arg" in
        provisionar|ca|verificar) acao=("$arg") ;;
        *) resto+=("$arg") ;;
    esac
done
analisar_argumentos "${resto[@]}"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] ${acao[*]:-provisionar} o tópico, o usuário SCRAM e o CA no Vault, com bootstrap $INFRA_FQDN:9092"
    exit 0
fi
export VAULT_URL="${VAULT_URL:-https://uniplus-vault.unifesspa.edu.br}"
export HOST_IP="$INFRA_FQDN"
exec "$SCRIPT_DIR/../hml-standalone-single/provision-registro-de-acesso-kafka.sh" "${acao[@]}"
