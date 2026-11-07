#!/usr/bin/env bash
# Provisiona no Vault de produção o que o KES, o RabbitMQ e o MinIO precisam
# (Transit, política e role do KES, identidades, senhas), reaproveitando o script
# de homologação com o certificado curinga da instituição como certificado do
# servidor KES. A VM de infraestrutura fala com o Vault pelo endereço público.
#
# Uso: [VAULT_URL=...] ./provisionar-verificacao.sh
# Rodar na VM de infraestrutura, depois de semear-vault.sh e com o Vault aberto.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] provisionaria no Vault, com o KES_CERT_FILE e KES_KEY_FILE do certificado curinga (script de homologação, com VAULT_URL=${VAULT_URL:-https://uniplus-vault.unifesspa.edu.br})"
    exit 0
fi

export VAULT_URL="${VAULT_URL:-https://uniplus-vault.unifesspa.edu.br}"
export HOST_IP="$APP_IP"
export KES_CERT_FILE="$TLS_BUNDLE"
export KES_KEY_FILE="$TLS_KEY"
exec "$SCRIPT_DIR/../hml-standalone-single/provision-verificacao-prerequisites.sh"
