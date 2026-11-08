#!/usr/bin/env bash
# Preparo comum dos scripts de provisionamento que rodam na VM de infraestrutura
# e gravam segredos no Vault da VM de aplicação pelo endereço público dele.
# Carregado com `source`, depois de lib-comum.sh.
#
# O token do Vault vem de ROOT_TOKEN ou é pedido sem eco; nunca vai a argv nem a
# arquivo versionado. Os temporários ficam em ~/tmp/prod (0700) e são destruídos
# na saída.

# VAULT_URL vazio (definido de propósito) usa o port-forward do host do cluster; sem
# a variável, vale o Vault público do ambiente (NOME_DO_VAULT).
definir_url_do_vault
PROVISIONAR_TMP=""

# shellcheck source=lib-vault.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-vault.sh"

limpar_provisionamento() {
    if [[ -n "$PROVISIONAR_TMP" && -d "$PROVISIONAR_TMP" ]]; then
        find "$PROVISIONAR_TMP" -type f -exec shred -u {} + 2>/dev/null || true
        rm -rf "$PROVISIONAR_TMP"
    fi
    vault_desconectar
}

preparar_provisionamento() {
    install -d -m 700 "$HOME/tmp/prod"
    PROVISIONAR_TMP=$(mktemp -d "$HOME/tmp/prod/provisionar-XXXXXX")
    trap limpar_provisionamento EXIT
    vault_conectar "$PROVISIONAR_TMP"
}

# Executa SQL como superusuário no container do PostgreSQL, com a senha em arquivo
# de ambiente 0600 (nunca em argv). O SQL vem da entrada padrão; APP_PW, quando
# definida, chega ao psql como variável de ambiente (\getenv).
psql_superusuario() {
    local env_file="$PROVISIONAR_TMP/postgres.env"
    {
        printf 'PGPASSWORD=%s\n' "$(ler_credencial "$DATA_BASE/postgres/.bootstrap-creds" super_pw)"
        [[ -z "${APP_PW:-}" ]] || printf 'APP_PW=%s\n' "$APP_PW"
    } >"$env_file"
    chmod 600 "$env_file"
    sudo docker exec --env-file "$env_file" -i uniplus-postgres \
        psql -U postgres -v ON_ERROR_STOP=1 -tA "$@"
}

# Grava no Vault só se o caminho (<sistema>/<caminho>) ainda não existe: nunca
# troca segredo vivo.
garantir_no_vault() {
    local caminho="$1"
    shift
    if vault_existe "$caminho"; then
        log_success "$caminho já existe no Vault; preservado."
    else
        vault_put "$caminho" "$@"
        log_success "$caminho gravado no Vault."
    fi
}

# Grava o mesmo segredo no KV de cada sistema que o consome: o isolamento por
# sistema impede um sistema de ler o KV do outro, então o segredo compartilhado
# (Redis, MinIO raiz, administrador do Kafka, SMTP) existe em cada um.
# Uso: garantir_compartilhado "uniplus plataforma" <caminho interno> chave=valor...
garantir_compartilhado() {
    local sistemas="$1" interno="$2" sistema
    shift 2
    for sistema in $sistemas; do
        garantir_no_vault "$sistema/$interno" "$@"
    done
}
