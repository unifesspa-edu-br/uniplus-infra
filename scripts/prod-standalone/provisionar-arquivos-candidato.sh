#!/usr/bin/env bash
# Provisiona o armazenamento cifrado dos arquivos do candidato (KES, buckets,
# políticas e usuários do MinIO) reaproveitando o script de homologação. O MinIO
# fica nesta VM e o KES no cluster da VM de aplicação: a ligação usa TLS com
# validação do certificado, pelo nome KES_HOST, na porta 7373.
#
# Uso: [VAULT_URL=...] [KES_HOST=...] ./provisionar-arquivos-candidato.sh
# Rodar na VM de infraestrutura, depois de o KES estar saudável no cluster.
# Exige que a porta 7373 da VM de aplicação esteja aberta para esta VM.
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
    echo "[DRY-RUN] provisionaria o KES, os buckets e os usuários do MinIO (script de homologação, com VAULT_URL=${VAULT_URL:-https://uniplus-vault.unifesspa.edu.br})"
    exit 0
fi

export VAULT_URL="${VAULT_URL:-https://uniplus-vault.unifesspa.edu.br}"
export HOST_IP="$INFRA_IP"
export KES_HOST="${KES_HOST:-uniplus-prod-app.unifesspa.edu.br}"
export MINIO_HOST="$INFRA_FQDN"
export MINIO_SCHEME=https
export KES_CA_FILE="$TLS_BUNDLE"
export ORIGEM_WEB="${ORIGEM_WEB:-https://uniplus.unifesspa.edu.br}"
exec "$SCRIPT_DIR/../hml-standalone-single/provision-arquivos-candidato.sh"
