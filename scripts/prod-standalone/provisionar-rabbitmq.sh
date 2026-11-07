#!/usr/bin/env bash
# Cria no RabbitMQ de produção o vhost da verificação e os usuários da API e do
# verificador, com a senha lida do Vault, pela API de gerência em HTTPS com
# validação do certificado. Idempotente: PUT substitui.
#
# Uso: [VAULT_URL=...] ./provisionar-rabbitmq.sh [--dry-run]
# Rodar na VM de infraestrutura depois de provisionar-verificacao.sh, que grava
# as senhas dos dois usuários no Vault.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

VHOST="verificacao"
BASE="https://$INFRA_FQDN:15671/api"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

# Chama a API de gerência com o administrador; a credencial vai em arquivo de
# configuração do curl 0600, nunca em argv.
chamar_api() {
    local metodo="$1" caminho="$2" corpo="${3:-}"
    local args=(-fsS --max-time 20 --config "$PROVISIONAR_TMP/rabbitmq.curl"
        --cacert "$TLS_BUNDLE" --resolve "$INFRA_FQDN:15671:127.0.0.1" -X "$metodo")
    if [[ -n "$corpo" ]]; then
        # O corpo pode ter senha: vai pela entrada padrão, nunca por argv.
        printf '%s' "$corpo" | curl "${args[@]}" -H 'Content-Type: application/json' --data-binary @- \
            "$BASE/$caminho" -o /dev/null
    else
        curl "${args[@]}" "$BASE/$caminho" -o /dev/null
    fi
}

provisionar_usuario() {
    local caminho="$1" usuario senha
    usuario=$(vault_get "$caminho" username)
    senha=$(vault_get "$caminho" password)
    chamar_api PUT "users/$usuario" \
        "$(RABBIT_SENHA="$senha" python3 -c 'import json, os; print(json.dumps({"password": os.environ["RABBIT_SENHA"], "tags": ""}))')"
    chamar_api PUT "permissions/$VHOST/$usuario" '{"configure":".*","write":".*","read":".*"}'
    log_success "Usuário $usuario com permissões no vhost $VHOST."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] PUT $BASE/vhosts/$VHOST e usuários de secret/standalone/rabbitmq/{api,verificador}"
    exit 0
fi
preparar_provisionamento
printf 'user = "rabbitmq-admin:%s"\n' "$(ler_credencial "$DATA_BASE/rabbitmq/.bootstrap-creds" admin_pw)" \
    >"$PROVISIONAR_TMP/rabbitmq.curl"
chmod 600 "$PROVISIONAR_TMP/rabbitmq.curl"
chamar_api PUT "vhosts/$VHOST" '{"default_queue_type":"quorum"}'
provisionar_usuario standalone/rabbitmq/api
provisionar_usuario standalone/rabbitmq/verificador
