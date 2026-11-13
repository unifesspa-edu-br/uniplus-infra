#!/usr/bin/env bash
# Funções comuns aos scripts que criam usuários SCRAM e ACLs no Kafka da VM de
# infraestrutura. É carregado com `source`, nunca executado, depois de lib-comum.sh
# e de lib-provisionar.sh (ou lib-vault.sh).
#
# O script que o carrega define antes:
#   KAFKA_IMAGE, BOOTSTRAP, ADMIN_PROPERTIES, CA_CRT   imagem, broker, credencial `admin` e CA
#   USUARIO, VAULT_CAMINHO                              usuário SCRAM e onde a senha dele vive
#
# Toda ferramenta do Kafka roda em contêiner descartável com a credencial `admin`
# (admin.properties montado só leitura). A senha de um usuário nunca vai a argv:
# chega ao contêiner por stdin.

ROTEIROS_KAFKA="$(dirname "${BASH_SOURCE[0]}")/kafka"

falha() { log_error "$*"; exit 1; }

# Só ASCII: letras, dígitos e ._~- (bytes fora disso não casam com LC_ALL=C).
senha_no_alfabeto() { [[ "$1" =~ ^[0-9A-Za-z._~-]+$ ]]; }

# Ferramenta do Kafka como `admin`; o broker e a credencial já vão no fim da linha.
# Desde o Kafka 4.2 (KIP-1147) todas as ferramentas, inclusive os clientes de console,
# aceitam `--command-config`; a imagem é a fixada em instalar-kafka.sh (apache/kafka:4.2.0).
# Uso: kafka_admin <ferramenta.sh> <argumentos>...
kafka_admin() {
    local ferramenta="$1"
    shift
    sudo docker run --rm -i --network host \
        -v "$ADMIN_PROPERTIES:/tmp/admin.properties:ro" \
        -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" \
        --entrypoint "/opt/kafka/bin/$ferramenta" "$KAFKA_IMAGE" "$@" \
        --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties
}

# Roteiro de kafka/ dentro de um contêiner descartável; a senha chega por stdin.
# O modo `admin` monta também o admin.properties; o modo `usuario` não, para que a
# verificação feita com a credencial de um usuário nunca enxergue a do administrador.
# Uso: _roteiro_no_conteiner admin|usuario <arquivo> [NOME=valor]...
_roteiro_no_conteiner() {
    local modo="$1" roteiro="$2" arg envs=() montagens=()
    shift 2
    for arg in "$@"; do envs+=(-e "$arg"); done
    [[ "$modo" != admin ]] || montagens+=(-v "$ADMIN_PROPERTIES:/tmp/admin.properties:ro")
    sudo docker run --rm -i --network host \
        -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" \
        -v "$ROTEIROS_KAFKA/$roteiro:/tmp/roteiro.sh:ro" "${montagens[@]}" \
        -e "BOOTSTRAP=$BOOTSTRAP" -e "USUARIO=$USUARIO" "${envs[@]}" \
        --entrypoint sh "$KAFKA_IMAGE" /tmp/roteiro.sh
}

conteiner_admin_com_roteiro() { _roteiro_no_conteiner admin "$@"; }
conteiner_usuario_com_roteiro() { _roteiro_no_conteiner usuario "$@"; }

senha_do_vault() {
    vault_get "$VAULT_CAMINHO" password \
        || falha "senha de $USUARIO ausente no Vault ($VAULT_CAMINHO); rodar 'provisionar'"
}

# Aplica no broker a senha que está no Vault (o upsert SCRAM é idempotente). O arquivo
# de credencial é lido como Java properties, que interpreta escapes e bytes não ASCII;
# uma senha fora do alfabeto que estes scripts geram chegaria alterada, então é recusada.
aplicar_usuario_scram() {
    local senha
    senha=$(senha_do_vault)
    LC_ALL=C senha_no_alfabeto "$senha" \
        || falha "a senha de $USUARIO no Vault tem caractere fora de [0-9A-Za-z._~-]; gerar outra"
    log_info "Aplicando o usuário SCRAM $USUARIO"
    printf '%s\n' "$senha" | conteiner_admin_com_roteiro definir-senha-scram.sh
}

# Falha se alguma ACL que alcança o usuário (dele ou do curinga `User:*`), em qualquer
# recurso, padrão ou permissão, fugir do conjunto esperado. É esta conferência que prova
# a ausência de Delete, Alter, Create e de ACL prefixada ou com curinga: tentar apagar ou
# alterar de verdade só provaria algo se a conta tivesse permissão demais.
# Uso: conferir_acls_do_usuario <descrição do conjunto> <TIPO|nome|PADRÃO|User:x|OP|PERMISSÃO>...
conferir_acls_do_usuario() {
    local descricao="$1" acls alcancadas esperadas
    shift
    acls=$(kafka_admin kafka-acls.sh --list)
    alcancadas=$(awk -v u="User:$USUARIO" '
        /^Current ACLs for resource/ {
            r = $0
            sub(/^[^(]*\(/, "", r); sub(/\)`?:? *$/, "", r)
            gsub(/resourceType=|name=|patternType=/, "", r); gsub(/, /, "|", r)
            next
        }
        /principal=/ {
            p = $0; sub(/.*principal=/, "", p); sub(/,.*/, "", p)
            o = $0; sub(/.*operation=/, "", o); sub(/,.*/, "", o)
            t = $0; sub(/.*permissionType=/, "", t); sub(/\).*/, "", t)
            if (p == u || p == "User:*") print r "|" p "|" o "|" t
        }' <<<"$acls" | sort)
    esperadas=$(printf '%s\n' "$@" | sort)
    if [[ "$alcancadas" != "$esperadas" ]]; then
        echo "ACLs que alcançam $USUARIO:" >&2
        echo "$alcancadas" >&2
        falha "as ACLs de $USUARIO (ou do curinga User:*) diferem do esperado ($descricao)"
    fi
}
