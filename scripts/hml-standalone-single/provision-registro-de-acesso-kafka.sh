#!/usr/bin/env bash
# Provisiona, no Kafka de HML, a trilha do registro de acesso a dado protegido
# (ADR-0153 do uniplus-api, uniplus-infra#752):
#
#   - tópico `autorizacao_registros_de_acesso`: 3 partições, fator de replicação 1
#     (nó único), `retention.ms=-1` e `cleanup.policy=delete`;
#   - usuário SCRAM `uniplus-api-registro-acesso-svc`, com senha gerada aqui e
#     guardada só no Vault (`secret/standalone/kafka/<usuário>`);
#   - CA do broker em `secret/standalone/kafka/ca` (chave `ca_cert`), de onde o
#     ExternalSecret do chart `uniplus-api-host` o lê. É certificado público,
#     lido de /etc/uniplus-kafka/certs/ca.crt, mas é gravado sem passar por argv;
#   - ACL literal no tópico: só `Write` e `Describe`. Sem `Create`, `Delete`,
#     `Alter` nem `Read`; o atalho `--producer` concede `Create` e por isso não
#     é usado.
#
# Uso (na VM de HML, com o ROOT_TOKEN do Vault no ambiente ou no ~/.bashrc):
#   provision-registro-de-acesso-kafka.sh [provisionar]   cria o que falta
#   provision-registro-de-acesso-kafka.sh ca             grava só o CA do broker no Vault
#   provision-registro-de-acesso-kafka.sh verificar       prova o que a ACL permite e recusa
#
# `provisionar` é idempotente: a senha existente no Vault é reaproveitada, o
# usuário e as configurações do tópico são reaplicados. `verificar` usa um
# contêiner descartável (`--rm`) com a credencial do registro de acesso: confere as
# ACLs (só Write e Describe literais, nada por curinga ou prefixo), publica uma
# mensagem de teste (só com o tópico vazio e a API ainda sem usá-lo) e tenta ler e
# criar um tópico descartável. Não tenta apagar nem alterar o tópico real. A
# senha entra nos contêineres por stdin: não aparece em argv do `docker run`,
# em arquivo nem na saída.
#
# Variáveis:
#   HOST_IP       IP do broker (default 192.168.21.134)
#   DATA_BASE     default /var/lib/uniplus
#   KAFKA_IMAGE   default apache/kafka:4.2.0
set -euo pipefail

HOST_IP="${HOST_IP:-192.168.21.134}"
DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
KAFKA_IMAGE="${KAFKA_IMAGE:-apache/kafka:4.2.0}"
BOOTSTRAP="$HOST_IP:9092"
USUARIO="uniplus-api-registro-acesso-svc"
TOPICO="autorizacao_registros_de_acesso"
PARTICOES=3
VAULT_CAMINHO="standalone/kafka/$USUARIO"
VAULT_CAMINHO_CA="standalone/kafka/ca"
ADMIN_PROPERTIES="$DATA_BASE/kafka/admin.properties"
CA_CRT="/etc/uniplus-kafka/certs/ca.crt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
falha() { echo "ERRO: $*" >&2; exit 1; }

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

# Ferramenta do Kafka com a credencial `admin` (admin.properties montado só leitura).
kafka_admin() {
    local ferramenta="$1"
    shift
    sudo docker run --rm --network host \
        -v "$ADMIN_PROPERTIES:/tmp/admin.properties:ro" \
        -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" \
        --entrypoint "/opt/kafka/bin/$ferramenta" "$KAFKA_IMAGE" "$@"
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
        -e "BOOTSTRAP=$BOOTSTRAP" -e "USUARIO=$USUARIO" -e "TOPICO=$TOPICO" \
        --entrypoint sh "$KAFKA_IMAGE" -c "$roteiro"
}

senha_do_vault() {
    vault_get "$VAULT_CAMINHO" password || falha "senha de $USUARIO ausente no Vault ($VAULT_CAMINHO); rodar 'provisionar'"
}

# Grava o CA do broker no Vault (chave ca_cert), se ainda não está igual. O PEM não passa
# por argv: vai de arquivo 0600 do tmpdir para o corpo da requisição (`@arquivo`) e é
# apagado em seguida. Sem esta etapa o ExternalSecret do chart não resolve o CA.
gravar_ca() {
    local pem="$tmpdir/ca.crt" corpo="$tmpdir/ca-corpo.json" atual
    sudo cat "$CA_CRT" | ( umask 077; cat >"$pem" )
    openssl x509 -in "$pem" -noout >/dev/null 2>&1 || { rm -f "$pem"; falha "$CA_CRT não é um certificado PEM válido"; }
    if atual=$(vault_get "$VAULT_CAMINHO_CA" ca_cert) && [[ "$atual" == "$(cat "$pem")" ]]; then
        log "CA do broker já está no Vault ($VAULT_CAMINHO_CA); nada a fazer."
        rm -f "$pem"
        return 0
    fi
    log "Gravando o CA do broker no Vault ($VAULT_CAMINHO_CA, chave ca_cert)"
    ( umask 077; python3 -c '
import json, sys
print(json.dumps({"data": {"ca_cert": open(sys.argv[1]).read().rstrip("\n")}}))' "$pem" >"$corpo" )
    VAULT_BODY_FILE="$tmpdir/vault-resposta.json"
    VAULT_HTTP_STATUS=$(curl -sS --config "$VAULT_CURL_CONFIG" -X POST -H 'Content-Type: application/json' \
        --data-binary "@$corpo" -o "$VAULT_BODY_FILE" -w '%{http_code}' "$VAULT_ADDR/v1/secret/data/$VAULT_CAMINHO_CA")
    rm -f "$corpo"
    [[ "$VAULT_HTTP_STATUS" == 200 ]] || { rm -f "$pem"; falha "Vault respondeu HTTP $VAULT_HTTP_STATUS ao gravar $VAULT_CAMINHO_CA"; }
    [[ "$(vault_get "$VAULT_CAMINHO_CA" ca_cert)" == "$(cat "$pem")" ]] \
        || { rm -f "$pem"; falha "o CA lido do Vault difere do gravado"; }
    rm -f "$pem"
}

provisionar() {
    vault_conectar "$tmpdir"

    # 1) Senha: gerada uma vez e gravada no Vault ANTES de ser aplicada no
    # broker, para nunca existir um usuário cuja senha ninguém guardou.
    local senha
    if vault_existe "$VAULT_CAMINHO"; then
        log "Senha de $USUARIO já está no Vault; reaproveitando."
        senha=$(senha_do_vault)
    else
        log "Gerando a senha de $USUARIO e gravando no Vault ($VAULT_CAMINHO)"
        senha=$(openssl rand -hex 32)
        vault_put "$VAULT_CAMINHO" "username=$USUARIO" "password=$senha"
        [[ "$(senha_do_vault)" == "$senha" ]] || falha "a senha lida do Vault difere da gravada"
    fi

    # 2) Usuário SCRAM (o upsert é idempotente). O Kafka 4.x exige a senha no
    # argumento do kafka-configs; ela fica só dentro do contêiner descartável.
    log "Aplicando o usuário SCRAM $USUARIO"
    # shellcheck disable=SC2016  # expansão deliberada dentro do contêiner
    printf '%s\n' "$senha" | kafka_sh_com_senha \
        'read -r APP_PW; exec /opt/kafka/bin/kafka-configs.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties --alter --add-config "SCRAM-SHA-512=[password=$APP_PW]" --entity-type users --entity-name "$USUARIO"' admin
    unset senha

    # 3) Tópico. Existente com outro número de partições é divergência a resolver
    # à mão: aumentar partições muda a chave de ordenação, e reduzir não existe.
    log "Criando o tópico $TOPICO (se ainda não existir)"
    kafka_admin kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --create --if-not-exists --topic "$TOPICO" --partitions "$PARTICOES" --replication-factor 1 \
        --config retention.ms=-1 --config cleanup.policy=delete
    local descricao
    descricao=$(kafka_admin kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --describe --topic "$TOPICO")
    grep -q "PartitionCount: $PARTICOES" <<<"$descricao" \
        || falha "o tópico $TOPICO existe com número de partições diferente de $PARTICOES"
    kafka_admin kafka-configs.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --alter --entity-type topics --entity-name "$TOPICO" \
        --add-config retention.ms=-1,cleanup.policy=delete

    # 4) ACL literal: só Write e Describe.
    log "Concedendo Write e Describe em $TOPICO a User:$USUARIO"
    kafka_admin kafka-acls.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --add --allow-principal "User:$USUARIO" --operation Write --operation Describe --topic "$TOPICO"

    local acls
    acls=$(kafka_admin kafka-acls.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --list --principal "User:$USUARIO")
    echo "$acls"
    local operacoes
    operacoes=$(grep -o 'operation=[A-Za-z]*' <<<"$acls" | sort | tr '\n' ' ')
    [[ "$operacoes" == "operation=DESCRIBE operation=WRITE " ]] \
        || falha "ACLs de $USUARIO diferentes de Write e Describe: $operacoes"
    grep -q 'patternType=LITERAL' <<<"$acls" || falha "a ACL de $USUARIO não é literal"

    gravar_ca

    log "Provisionamento concluído. Rodar 'verificar' em seguida."
}

# Soma, nas partições do tópico, (fim - início) dos offsets: 0 = tópico vazio.
registros_no_topico() {
    local fim inicio
    fim=$(kafka_admin kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --topic "$TOPICO" --time -1 | awk -F: '{s+=$3} END{print s+0}')
    inicio=$(kafka_admin kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --topic "$TOPICO" --time -2 | awk -F: '{s+=$3} END{print s+0}')
    echo $((fim - inicio))
}

# Falha se alguma ACL que alcança o usuário (dele ou do curinga `User:*`), em qualquer
# recurso, padrão ou permissão, fugir de Write e Describe LITERAIS neste tópico. É esta
# conferência, e não uma tentativa de apagar ou alterar o tópico, que prova a ausência
# de Delete, Alter, Read, Create e de ACL prefixada ou com curinga: se a conta tivesse
# permissão demais, a tentativa executaria de verdade na trilha.
conferir_acls() {
    local acls alcancadas esperadas
    acls=$(kafka_admin kafka-acls.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties --list)
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
    esperadas=$(printf '%s\n' \
        "TOPIC|$TOPICO|LITERAL|User:$USUARIO|DESCRIBE|ALLOW" \
        "TOPIC|$TOPICO|LITERAL|User:$USUARIO|WRITE|ALLOW" | sort)
    if [[ "$alcancadas" != "$esperadas" ]]; then
        echo "ACLs que alcançam $USUARIO:" >&2
        echo "$alcancadas" >&2
        falha "as ACLs de $USUARIO (ou do curinga User:*) diferem de Write e Describe literais em $TOPICO"
    fi
    log "ACLs conferidas: só Write e Describe literais em $TOPICO, nada por curinga ou prefixo."
}

# A API já usa o tópico se o Deployment do host tem a variável do registro de acesso.
# Na dúvida (kubectl sem resposta, nenhum Deployment), conta como em uso.
api_usa_o_topico() {
    local envs
    envs=$(sudo kubectl --kubeconfig "$KUBECONFIG_PATH" -n "${NAMESPACE_API:-uniplus}" get deploy \
        -l app.kubernetes.io/name=uniplus-api-host \
        -o jsonpath='{range .items[*].spec.template.spec.containers[*].env[*]}{.name}{"\n"}{end}' 2>/dev/null) || return 0
    [[ -n "$envs" ]] || return 0
    grep -qx 'RegistroDeAcesso__Kafka__BootstrapServers' <<<"$envs"
}

# Fim (offset do próximo registro) de uma partição do tópico.
fim_da_particao() {
    kafka_admin kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --topic "$TOPICO" --time -1 | awk -F: -v p="$1" '$2 == p {print $3}'
}

verificar() {
    vault_conectar "$tmpdir"
    local senha
    senha=$(senha_do_vault)

    conferir_acls

    # A mensagem de teste só é escrita com o tópico vazio e a API ainda sem usá-lo: assim
    # ninguém além deste script escreve nele, e o registro de teste é o único a remover.
    local publicar=1
    if [[ "$(registros_no_topico)" -ne 0 ]]; then
        publicar=0
        log "AVISO: o tópico já tem registros; a publicação de teste NÃO será feita."
    elif api_usa_o_topico; then
        publicar=0
        log "AVISO: a API já usa o tópico (ou não foi possível conferir); a publicação de teste NÃO será feita."
    fi
    local fim_antes=("" "" "")
    if [[ "$publicar" == 1 ]]; then
        local p
        for p in 0 1 2; do fim_antes[p]=$(fim_da_particao "$p"); done
    fi

    # Roteiro executado DENTRO do contêiner descartável com a credencial do registro de
    # acesso. A senha vem por stdin e só é escrita no /tmp do próprio contêiner, que some
    # com ele (--rm). Nada aqui apaga ou altera o tópico real.
    # shellcheck disable=SC2016  # expansões deliberadas dentro do contêiner
    local roteiro='
read -r SENHA
C=/tmp/cliente.properties
cat > "$C" <<PROP
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$USUARIO" password="$SENHA";
ssl.truststore.type=PEM
ssl.truststore.location=/etc/uniplus-kafka/certs/ca.crt
ssl.endpoint.identification.algorithm=
enable.idempotence=true
PROP
B=/opt/kafka/bin
N=verificacao_752_negativa

recusado() { # $1 = nome, $2 = arquivo de saída. Os clientes de console saem com 0 mesmo
  # quando o broker recusa, então a recusa se reconhece pela exceção de autorização.
  if grep -qi "authorization\|not authorized" "$2" && ! grep -q "752\\.0" "$2"; then
    echo "$1: RECUSADO pelo broker (autorização)"
  else
    echo "$1: NAO RECUSADO <<<<<< FALHA"; sed "s/$SENHA/***/g" "$2" | tail -5
  fi
}

if [ "$PUBLICAR" = 1 ]; then
  # O produtor verificável devolve partição e offset gravados no broker.
  $B/kafka-verifiable-producer.sh --bootstrap-server "$BOOTSTRAP" --producer.config "$C" --topic "$TOPICO" \
    --max-messages 1 --acks -1 --value-prefix 752 >/tmp/o_pub 2>&1
  echo "publicar: rc=$?"
  grep "producer_send_success" /tmp/o_pub | sed "s/^/produce: /"
  grep -qi "authorization" /tmp/o_pub && echo "publicar: BROKER RECUSOU <<<<<< FALHA"
fi

# Describe: listar offsets pede só Describe no tópico (kafka-topics --describe pede também DescribeConfigs).
$B/kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --command-config "$C" --topic "$TOPICO" --time -1 >/tmp/o_desc 2>&1
rc=$?
echo "descrever (Describe): rc=$rc"
[ "$rc" -ne 0 ] && echo "descrever: FALHA"

$B/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP" --consumer.config "$C" --topic "$TOPICO" \
  --from-beginning --max-messages 1 --timeout-ms 15000 --group verificacao-752 >/tmp/o_ler 2>&1
recusado "ler (Read)" /tmp/o_ler

# Sem assinatura de grupo (atribuição manual), a recusa vem do Read no próprio tópico.
$B/kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP" --consumer.config "$C" --topic "$TOPICO" \
  --partition 0 --offset earliest --max-messages 1 --timeout-ms 15000 >/tmp/o_ler2 2>&1
recusado "ler o tópico sem grupo (Read)" /tmp/o_ler2

# Tópico descartável: se a criação passar, o roteiro do host o apaga e a verificação falha.
$B/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config "$C" --create --topic "$N" \
  --partitions 1 --replication-factor 1 >/tmp/o_cri 2>&1
recusado "criar outro tópico (Create)" /tmp/o_cri
'
    log "Rodando o cliente temporário (contêiner --rm) com a credencial $USUARIO"
    local resultado
    resultado=$(printf '%s\n' "$senha" | sudo docker run --rm -i --network host \
        -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" \
        -e "BOOTSTRAP=$BOOTSTRAP" -e "USUARIO=$USUARIO" -e "TOPICO=$TOPICO" -e "PUBLICAR=$publicar" \
        --entrypoint sh "$KAFKA_IMAGE" -c "$roteiro")
    unset senha
    echo "$resultado"

    # O tópico descartável não pode sobrar, passe ou não a verificação.
    local descartavel=verificacao_752_negativa
    if kafka_admin kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties --list \
        | grep -qx "$descartavel"; then
        kafka_admin kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
            --delete --topic "$descartavel"
        falha "a credencial criou o tópico $descartavel (apagado): tem mais permissão do que deveria"
    fi
    if grep -q 'FALHA' <<<"$resultado"; then
        falha "a credencial do registro de acesso tem mais (ou menos) permissão do que deveria"
    fi

    log "Conferindo o estado do tópico como admin"
    kafka_admin kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --describe --topic "$TOPICO"
    kafka_admin kafka-configs.sh --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
        --describe --entity-type topics --entity-name "$TOPICO"

    if [[ "$publicar" == 1 ]]; then
        # Partição e offset devolvidos pelo broker à própria mensagem de teste.
        local enviado particao offset
        enviado=$(grep 'producer_send_success' <<<"$resultado" | head -n1)
        particao=$(sed -n 's/.*"partition":\([0-9]*\).*/\1/p' <<<"$enviado")
        offset=$(sed -n 's/.*"offset":\([0-9]*\).*/\1/p' <<<"$enviado")
        [[ -n "$particao" && -n "$offset" ]] || falha "o produtor não devolveu partição e offset; nada foi removido"
        # Tópico vazio antes do teste: o offset devolvido tem de ser o fim anterior da partição.
        if [[ "$offset" != "${fim_antes[particao]}" ]]; then
            log "AVISO: offset devolvido ($offset) difere do esperado (${fim_antes[particao]}) na partição $particao; NADA foi removido. Conferir o tópico à mão."
            falha "offset inesperado para o registro de teste"
        fi
        local lido
        lido=$(kafka_admin kafka-console-consumer.sh --bootstrap-server "$BOOTSTRAP" \
            --consumer.config /tmp/admin.properties --topic "$TOPICO" --partition "$particao" --offset "$offset" \
            --max-messages 1 --timeout-ms 15000 2>/dev/null)
        grep -qx '752\.0' <<<"$lido" || falha "o registro de teste não foi lido de volta pelo admin"
        log "Publicação confirmada (partição $particao, offset $offset). Removendo só esse registro."
        local alvo="$tmpdir/offsets.json"
        printf '{"version":1,"partitions":[{"topic":"%s","partition":%s,"offset":%s}]}\n' \
            "$TOPICO" "$particao" "$((offset + 1))" >"$alvo"
        sudo docker run --rm -v "$alvo:/tmp/offsets.json:ro" -v "$ADMIN_PROPERTIES:/tmp/admin.properties:ro" \
            -v "$CA_CRT:/etc/uniplus-kafka/certs/ca.crt:ro" --network host \
            --entrypoint /opt/kafka/bin/kafka-delete-records.sh "$KAFKA_IMAGE" \
            --bootstrap-server "$BOOTSTRAP" --command-config /tmp/admin.properties \
            --offset-json-file /tmp/offsets.json >/dev/null
    fi
    log "Verificação concluída: a credencial só escreve (e descreve) no tópico."
}

case "${1:-provisionar}" in
    provisionar) provisionar ;;
    ca) vault_conectar "$tmpdir"; gravar_ca ;;
    verificar) verificar ;;
    *) falha "uso: $0 [provisionar|ca|verificar]" ;;
esac
