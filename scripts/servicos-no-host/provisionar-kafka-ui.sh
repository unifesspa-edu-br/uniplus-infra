#!/usr/bin/env bash
# Provisiona, no Kafka, a credencial própria do Kafka UI (AKHQ, chart apps/kafka-ui),
# que substitui o `admin` (uniplus-infra#806):
#
#   - usuário SCRAM `uniplus-kafka-ui-svc`, com senha gerada aqui e guardada só no
#     Vault, junto com o CA do broker (`plataforma/kafka/kafka-ui`, chaves
#     `username`, `password` e `ca_cert`), de onde o ExternalSecret do chart a lê;
#   - ACLs só de consulta:
#       cluster              Describe, DescribeConfigs  (nós, configuração, ACLs)
#       tópicos `*`          Describe, DescribeConfigs, Read
#       grupos `*`           Describe                   (grupos e atraso)
#       trilha de acessos    DENY Read                  (literal)
#     Sem Write, Create, Delete nem Alter. A negação prevalece sobre qualquer
#     permissão no StandardAuthorizer: nenhuma ACL de leitura reabre a trilha.
#
# O `admin` é superusuário do broker (super.users) e passa por cima das ACLs; por
# isso o AKHQ nunca o usa.
#
# Uso (na VM de infraestrutura, com o ROOT_TOKEN do Vault no ambiente ou pedido no terminal):
#   provisionar-kafka-ui.sh [--dry-run] [provisionar]   cria ou reaplica o que falta
#   provisionar-kafka-ui.sh verificar                   prova o que a credencial lê e o que é recusado
#
# `provisionar` é idempotente: a senha existente no Vault é reaproveitada e o CA é
# regravado com o atual. `verificar` confere as ACLs e, num contêiner descartável
# (`--rm`) com a credencial do AKHQ, lista os offsets da trilha (permitido), tenta
# ler uma mensagem dela e tenta criar um tópico (os dois têm de ser recusados). Não
# lê nem altera nada da trilha. A senha entra nos contêineres por stdin: não
# aparece em argv do `docker run`, em arquivo do host nem na saída.
#
# Variáveis (as de lib-comum.sh valem aqui):
#   INFRA_FQDN    nome do broker, validado pelo certificado
#   KAFKA_IMAGE   default apache/kafka:4.2.0
#   VAULT_URL     ver lib-vault.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

KAFKA_IMAGE="${KAFKA_IMAGE:-apache/kafka:4.2.0}"
BOOTSTRAP="$INFRA_FQDN:9092"
USUARIO="uniplus-kafka-ui-svc"
TOPICO_TRILHA="autorizacao_registros_de_acesso"
TOPICO_DESCARTAVEL="verificacao_kafka_ui_negativa"
VAULT_CAMINHO="plataforma/kafka/kafka-ui"
ADMIN_PROPERTIES="$DATA_BASE/kafka/admin.properties"
CA_CRT="/etc/uniplus-kafka/certs/ca.crt"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
falha() { echo "ERRO: $*" >&2; exit 1; }
# Só ASCII: letras, dígitos e ._~- (bytes fora disso não casam com LC_ALL=C).
senha_no_alfabeto() { [[ "$1" =~ ^[0-9A-Za-z._~-]+$ ]]; }

mostrar_uso() {
    echo "Uso: $0 [--dry-run] [provisionar|verificar]"
}

acao=provisionar
resto=()
for arg in "$@"; do
    case "$arg" in
        provisionar|verificar) acao="$arg" ;;
        *) resto+=("$arg") ;;
    esac
done
analisar_argumentos "${resto[@]}"
exigir_usuario_comum
exigir_infra_fqdn
if $DRY_RUN; then
    echo "[DRY-RUN] $acao o usuário SCRAM $USUARIO, as ACLs só de consulta (DENY Read em $TOPICO_TRILHA)"
    echo "[DRY-RUN]   e $VAULT_CAMINHO (username, password, ca_cert), com bootstrap $BOOTSTRAP"
    exit 0
fi
definir_url_do_vault

tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
cleanup() {
    vault_desconectar 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# shellcheck source=lib-vault.sh
source "$SCRIPT_DIR/lib-vault.sh"
command -v docker >/dev/null || falha "docker ausente"
sudo test -r "$ADMIN_PROPERTIES" || falha "$ADMIN_PROPERTIES ausente ou ilegível"
sudo test -r "$CA_CRT" || falha "$CA_CRT ausente ou ilegível"

# Ferramenta do Kafka com a credencial `admin` (admin.properties montado só leitura).
kafka_admin() {
    local ferramenta="$1"
    shift
    sudo docker run --rm --network host \
        -v "$ADMIN_PROPERTIES:/tmp/admin.properties:ro" \
        -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" \
        --entrypoint "/opt/kafka/bin/$ferramenta" "$KAFKA_IMAGE" \
        --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties "$@"
}

# Contêiner com `sh -c <roteiro>`; a senha do usuário chega por stdin, que o roteiro lê.
# $1 = roteiro; $2 = "admin" monta também o admin.properties.
kafka_sh_com_senha() {
    local roteiro="$1" extra=()
    if [[ "${2:-}" == admin ]]; then
        extra=(-v "$ADMIN_PROPERTIES:/tmp/admin.properties:ro")
    fi
    sudo docker run --rm -i --network host \
        -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" "${extra[@]}" \
        -e "BOOTSTRAP=$BOOTSTRAP" -e "USUARIO=$USUARIO" -e "TOPICO=$TOPICO_TRILHA" \
        -e "DESCARTAVEL=$TOPICO_DESCARTAVEL" \
        --entrypoint sh "$KAFKA_IMAGE" -c "$roteiro"
}

senha_do_vault() {
    vault_get "$VAULT_CAMINHO" password || falha "senha de $USUARIO ausente no Vault ($VAULT_CAMINHO); rodar 'provisionar'"
}

# Reaproveita a senha do Vault ou gera uma nova; grava sempre com o CA atual do
# broker ANTES de aplicar no broker, para nunca existir usuário sem senha guardada.
garantir_senha_no_vault() {
    local senha
    if vault_existe "$VAULT_CAMINHO"; then
        log "Senha de $USUARIO já está no Vault; reaproveitando." >&2
        senha=$(senha_do_vault)
    else
        log "Gerando a senha de $USUARIO" >&2
        senha=$(openssl rand -hex 32)
    fi
    LC_ALL=C senha_no_alfabeto "$senha" \
        || falha "a senha de $USUARIO no Vault tem caractere fora de [0-9A-Za-z._~-]; gerar outra"
    log "Gravando $VAULT_CAMINHO (username, password, ca_cert)" >&2
    vault_put "$VAULT_CAMINHO" "username=$USUARIO" "password=$senha" "ca_cert=$(sudo cat "$CA_CRT")"
    [[ "$(senha_do_vault)" == "$senha" ]] || falha "a senha lida do Vault difere da gravada"
    printf '%s' "$senha"
}

# Usuário SCRAM (upsert idempotente). A credencial vai num arquivo 0600 do /tmp do
# contêiner descartável, lido por --add-config-file: argumento de processo aparece
# no `ps` do host, arquivo dentro do contêiner não.
aplicar_usuario() {
    log "Aplicando o usuário SCRAM $USUARIO"
    # shellcheck disable=SC2016  # expansão deliberada dentro do contêiner
    printf '%s\n' "$1" | kafka_sh_com_senha \
        'umask 077; read -r APP_PW; printf "SCRAM-SHA-512=password=%s\n" "$APP_PW" > /tmp/scram.properties; unset APP_PW
/opt/kafka/bin/kafka-configs.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties --alter --add-config-file /tmp/scram.properties --entity-type users --entity-name "$USUARIO"; s=$?; rm -f /tmp/scram.properties; exit $s' admin
}

aplicar_acls() {
    local p="User:$USUARIO"
    log "Aplicando as ACLs só de consulta de $p"
    kafka_admin kafka-acls.sh --add --allow-principal "$p" \
        --operation Describe --operation DescribeConfigs --cluster
    kafka_admin kafka-acls.sh --add --allow-principal "$p" \
        --operation Describe --operation DescribeConfigs --operation Read --topic '*'
    kafka_admin kafka-acls.sh --add --allow-principal "$p" --operation Describe --group '*'
    log "Negando Read em $TOPICO_TRILHA a $p"
    kafka_admin kafka-acls.sh --add --deny-principal "$p" --operation Read --topic "$TOPICO_TRILHA"
}

# Uma linha por ACL esperada: recurso|nome|padrão|principal|operação|permissão.
acls_esperadas() {
    local p="User:$USUARIO"
    printf '%s\n' \
        "CLUSTER|kafka-cluster|LITERAL|$p|DESCRIBE|ALLOW" \
        "CLUSTER|kafka-cluster|LITERAL|$p|DESCRIBE_CONFIGS|ALLOW" \
        "GROUP|*|LITERAL|$p|DESCRIBE|ALLOW" \
        "TOPIC|*|LITERAL|$p|DESCRIBE|ALLOW" \
        "TOPIC|*|LITERAL|$p|DESCRIBE_CONFIGS|ALLOW" \
        "TOPIC|*|LITERAL|$p|READ|ALLOW" \
        "TOPIC|$TOPICO_TRILHA|LITERAL|$p|READ|DENY" | sort
}

# ACLs que alcançam o usuário (dele ou do curinga `User:*`), no mesmo formato.
acls_que_alcancam() {
    kafka_admin kafka-acls.sh --list | awk -v u="User:$USUARIO" '
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
        }' | sort
}

# Falha se as ACLs que alcançam o usuário diferem, em qualquer linha, das esperadas:
# prova a ausência de Write, Create, Delete, Alter e de ACL por prefixo ou curinga
# de principal, sem precisar tentar a operação.
conferir_acls() {
    local alcancadas
    alcancadas=$(acls_que_alcancam)
    if [[ "$alcancadas" != "$(acls_esperadas)" ]]; then
        echo "ACLs que alcançam $USUARIO:" >&2
        echo "$alcancadas" >&2
        falha "as ACLs de $USUARIO (ou do curinga User:*) diferem das só de consulta"
    fi
    log "ACLs conferidas: só consulta, com Read negado em $TOPICO_TRILHA."
}

provisionar() {
    vault_conectar "$tmpdir"
    local senha
    senha=$(garantir_senha_no_vault)
    aplicar_usuario "$senha"
    unset senha
    aplicar_acls
    conferir_acls
    log "Provisionamento concluído. Rodar 'verificar' e, depois, sincronizar o kafka-ui."
}

# Roteiro executado DENTRO do contêiner descartável com a credencial do AKHQ. A senha
# vem por stdin e só é escrita no /tmp do próprio contêiner, que some com ele (--rm).
# Os clientes de console saem com 0 mesmo quando o broker recusa: a recusa se
# reconhece pela exceção de autorização na saída.
# shellcheck disable=SC2016  # expansões deliberadas dentro do contêiner
ROTEIRO_VERIFICAR='
read -r SENHA
C=/tmp/cliente.properties
cat > "$C" <<PROP
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$USUARIO" password="$SENHA";
ssl.truststore.type=PEM
ssl.truststore.location=/etc/uniplus-kafka/certs/ca.crt
ssl.endpoint.identification.algorithm=
PROP
B=/opt/kafka/bin

recusado() { # $1 = descrição, $2 = arquivo de saída
  if grep -qi "authorization\|not authorized" "$2"; then
    echo "$1: RECUSADO pelo broker (autorização)"
  else
    echo "$1: NAO RECUSADO <<<<<< FALHA"; sed "s/$SENHA/***/g" "$2" | tail -5
  fi
}

$B/kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --command-config "$C" --topic "$TOPICO" --time -1 >/tmp/o_desc 2>&1
rc=$?
echo "listar offsets da trilha (Describe): rc=$rc"
[ "$rc" -ne 0 ] && echo "listar offsets: FALHA"

$B/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP" --consumer.config "$C" --topic "$TOPICO" \
  --partition 0 --offset earliest --max-messages 1 --timeout-ms 15000 >/tmp/o_ler 2>&1
recusado "ler mensagem da trilha (Read)" /tmp/o_ler

$B/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config "$C" --create --topic "$DESCARTAVEL" \
  --partitions 1 --replication-factor 1 >/tmp/o_cri 2>&1
recusado "criar tópico (Create)" /tmp/o_cri
'

verificar() {
    vault_conectar "$tmpdir"
    local senha resultado
    senha=$(senha_do_vault)
    conferir_acls
    log "Rodando o cliente temporário (contêiner --rm) com a credencial $USUARIO"
    resultado=$(printf '%s\n' "$senha" | kafka_sh_com_senha "$ROTEIRO_VERIFICAR")
    unset senha
    echo "$resultado"

    # O tópico descartável não pode sobrar, passe ou não a verificação.
    if kafka_admin kafka-topics.sh --list | grep -qx "$TOPICO_DESCARTAVEL"; then
        kafka_admin kafka-topics.sh --delete --topic "$TOPICO_DESCARTAVEL"
        falha "a credencial criou o tópico $TOPICO_DESCARTAVEL (apagado): tem mais permissão do que deveria"
    fi
    grep -q 'FALHA' <<<"$resultado" && falha "a credencial do Kafka UI tem mais (ou menos) permissão do que deveria"
    log "Verificação concluída: a credencial consulta metadados e não lê a trilha de acessos."
}

case "$acao" in
    provisionar) provisionar ;;
    verificar) verificar ;;
    *) falha "uso: $0 [provisionar|verificar]" ;;
esac
