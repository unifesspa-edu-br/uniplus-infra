#!/usr/bin/env bash
# Grava no Vault de produção os segredos que nascem na VM de infraestrutura:
# Redis, usuário raiz do MinIO, administrador do RabbitMQ e as chaves locais de
# cifra das APIs. Só grava o que ainda não existe; nunca troca segredo vivo.
#
# Uso: [VAULT_URL=...] ./semear-vault.sh [--dry-run]
# Rodar na VM de infraestrutura, com o Vault inicializado e aberto. A
# inicialização do Vault (Shamir 5/3) é manual e fica fora dos scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

semear_servicos_de_dados() {
    garantir_no_vault standalone/redis/default \
        "username=default" "password=$(ler_credencial "$DATA_BASE/redis/.bootstrap-creds" default_pw)"
    garantir_no_vault standalone/minio/root \
        "username=$(ler_credencial "$DATA_BASE/minio/.bootstrap-creds" root_user)" \
        "password=$(ler_credencial "$DATA_BASE/minio/.bootstrap-creds" root_pw)"
    garantir_no_vault standalone/rabbitmq/admin \
        "username=rabbitmq-admin" "password=$(ler_credencial "$DATA_BASE/rabbitmq/.bootstrap-creds" admin_pw)"
}

semear_chaves_locais() {
    garantir_no_vault standalone/uniplus-api-host/encryption "local_key=$(openssl rand -base64 32)"
    garantir_no_vault standalone/geo/encryption "local_key=$(openssl rand -base64 32)"
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] gravaria no Vault, se ausentes: standalone/redis/default, standalone/minio/root,"
    echo "[DRY-RUN]   standalone/rabbitmq/admin, standalone/uniplus-api-host/encryption, standalone/geo/encryption"
    exit 0
fi
preparar_provisionamento
semear_servicos_de_dados
semear_chaves_locais
