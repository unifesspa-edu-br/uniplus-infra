#!/usr/bin/env bash
# Cria os roles e os bancos das aplicações no PostgreSQL de produção e guarda a
# senha de cada role no Vault. A senha nasce aqui, vai direto ao Vault e ao
# role, e não fica em disco: se o role já existe, a do Vault é reaplicada.
#
# Uso: [VAULT_URL=...] ./provisionar-bancos.sh [--dry-run]
# Rodar na VM de infraestrutura, com o Vault aberto.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

# role:banco:caminho da senha no Vault
BANCOS=(
    "uniplus:uniplus:standalone/postgres/uniplus"
    "portal:uniplus_portal:standalone/postgres/portal"
    "uniplus_geo_app:uniplus_geo:standalone/postgres/geo"
    "apicurio:apicurio:standalone/postgres/apicurio"
)

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

provisionar_banco() {
    local role="$1" banco="$2" caminho="$3" senha
    if vault_existe "$caminho"; then
        senha=$(vault_get "$caminho" password)
    else
        senha=$(openssl rand -hex 32)
        vault_put "$caminho" "username=$role" "password=$senha"
    fi

    APP_PW="$senha" psql_superusuario <<SQL >/dev/null
\getenv app_pw APP_PW
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$role') AS role_exists \gset
\if :role_exists
  ALTER ROLE $role WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\else
  CREATE ROLE $role WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif
SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$banco') AS banco_novo \gset
\if :banco_novo
  CREATE DATABASE $banco OWNER $role ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
\endif
GRANT ALL PRIVILEGES ON DATABASE $banco TO $role;
SQL
    log_success "Role $role e banco $banco prontos."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    for item in "${BANCOS[@]}"; do
        IFS=: read -r role banco caminho <<<"$item"
        echo "[DRY-RUN] role $role, banco $banco, senha em secret/$caminho"
    done
    exit 0
fi
preparar_provisionamento
for item in "${BANCOS[@]}"; do
    IFS=: read -r role banco caminho <<<"$item"
    provisionar_banco "$role" "$banco" "$caminho"
done
