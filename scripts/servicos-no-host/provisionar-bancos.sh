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

# role:banco:caminho da senha no Vault[:template]. O Geo nasce de template_postgis,
# que já traz as extensões do PostGIS: o role da aplicação não é superusuário e
# não conseguiria instalá-las.
BANCOS=(
    "uniplus:uniplus:uniplus/postgres"
    "portal:uniplus_portal:uniplus/postgres-portal"
    "uniplus_geo_app:uniplus_geo:geo/postgres:template_postgis"
    "apicurio:apicurio:plataforma/postgres/apicurio"
)

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

provisionar_banco() {
    local role="$1" banco="$2" caminho="$3" template="${4:-}" senha criacao
    if [[ -n "$template" ]]; then
        criacao="TEMPLATE $template"
    else
        criacao="ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
    fi
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
  CREATE DATABASE $banco OWNER $role $criacao;
\endif
GRANT ALL PRIVILEGES ON DATABASE $banco TO $role;
SQL
    log_success "Role $role e banco $banco prontos."
}

# Role do backup feito pelo pipeline antes de uma migration: lê todos os bancos
# (pg_read_all_data) e não tem privilégio de escrita nas tabelas das aplicações;
# a transação somente leitura por padrão evita escrita por engano. O pg_hba só o
# aceita da VM de automação.
CAMINHO_SENHA_BACKUP="plataforma/postgres/backup"

provisionar_role_de_backup() {
    local senha
    if vault_existe "$CAMINHO_SENHA_BACKUP"; then
        senha=$(vault_get "$CAMINHO_SENHA_BACKUP" password)
    else
        senha=$(openssl rand -hex 32)
        vault_put "$CAMINHO_SENHA_BACKUP" "username=$ROLE_BACKUP" "password=$senha"
    fi
    APP_PW="$senha" psql_superusuario <<SQL >/dev/null
\getenv app_pw APP_PW
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$ROLE_BACKUP') AS role_exists \gset
\if :role_exists
  ALTER ROLE $ROLE_BACKUP WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
\else
  CREATE ROLE $ROLE_BACKUP WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
\endif
GRANT pg_read_all_data TO $ROLE_BACKUP;
ALTER ROLE $ROLE_BACKUP SET default_transaction_read_only = on;
SQL
    log_success "Role $ROLE_BACKUP (somente leitura) pronto."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    for item in "${BANCOS[@]}"; do
        IFS=: read -r role banco caminho template <<<"$item"
        echo "[DRY-RUN] role $role, banco $banco${template:+ (de $template)}, senha em $caminho"
    done
    echo "[DRY-RUN] role $ROLE_BACKUP (pg_read_all_data, somente leitura), senha em $CAMINHO_SENHA_BACKUP"
    exit 0
fi
preparar_provisionamento
for item in "${BANCOS[@]}"; do
    IFS=: read -r role banco caminho template <<<"$item"
    provisionar_banco "$role" "$banco" "$caminho" "$template"
done
provisionar_role_de_backup
