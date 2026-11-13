#!/usr/bin/env bash
# Provisiona, no Kafka, a trilha do registro de acesso a dado protegido
# (ADR-0153 do uniplus-api, uniplus-infra#752):
#
#   - tópico `autorizacao_registros_de_acesso`: 3 partições, fator de replicação 1
#     (nó único), `retention.ms=-1` e `cleanup.policy=delete`;
#   - usuário SCRAM `uniplus-api-registro-acesso-svc`, com senha gerada aqui e
#     guardada só no Vault (`uniplus/kafka/<usuário>`, KV do Uni+);
#   - CA do broker em `uniplus/kafka/ca` (chave `ca_cert`), de onde o
#     ExternalSecret do chart `uniplus-api-host` o lê. É certificado público,
#     lido de /etc/uniplus-kafka/certs/ca.crt, mas é gravado sem passar por argv;
#   - ACL literal no tópico: só `Write` e `Describe`. Sem `Create`, `Delete`,
#     `Alter` nem `Read`; o atalho `--producer` concede `Create` e por isso não
#     é usado.
#
# Uso (na VM de infraestrutura, com o ROOT_TOKEN do Vault no ambiente ou pedido no terminal):
#   provisionar-kafka.sh [--dry-run] [provisionar]   cria o que falta
#   provisionar-kafka.sh ca                          grava só o CA do broker no Vault
#   provisionar-kafka.sh verificar                   prova o que a ACL permite e recusa
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
# Variáveis (as de lib-comum.sh valem aqui):
#   INFRA_FQDN    nome do broker, validado pelo certificado
#   BOOTSTRAP     default $INFRA_FQDN:9092
#   CA_CRT        CA do broker, default /etc/uniplus-kafka/certs/ca.crt
#   KAFKA_IMAGE   default apache/kafka:4.2.0
#   VAULT_URL     ver lib-vault.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

KAFKA_IMAGE="${KAFKA_IMAGE:-apache/kafka:4.2.0}"
BOOTSTRAP="${BOOTSTRAP:-$INFRA_FQDN:9092}"
USUARIO="uniplus-api-registro-acesso-svc"
TOPICO="autorizacao_registros_de_acesso"
PARTICOES=3
VAULT_CAMINHO="uniplus/kafka/$USUARIO"
VAULT_CAMINHO_CA="uniplus/kafka/ca"
ADMIN_PROPERTIES="$DATA_BASE/kafka/admin.properties"
CA_CRT="${CA_CRT:-/etc/uniplus-kafka/certs/ca.crt}"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

mostrar_uso() {
    echo "Uso: $0 [--dry-run] [provisionar|ca|verificar]"
}

acao=provisionar
resto=()
for arg in "$@"; do
    case "$arg" in
        provisionar|ca|verificar) acao="$arg" ;;
        *) resto+=("$arg") ;;
    esac
done
analisar_argumentos "${resto[@]}"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] $acao o tópico, o usuário SCRAM e o CA no Vault, com bootstrap $BOOTSTRAP"
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
# shellcheck source=lib-kafka.sh
source "$SCRIPT_DIR/lib-kafka.sh"
command -v docker >/dev/null || falha "docker ausente"
sudo test -r "$ADMIN_PROPERTIES" || falha "$ADMIN_PROPERTIES ausente ou ilegível"

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
        --data-binary "@$corpo" -o "$VAULT_BODY_FILE" -w '%{http_code}' "$VAULT_ADDR/v1/$(vault_caminho_dados "$VAULT_CAMINHO_CA")")
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

    # 2) Usuário SCRAM, com a senha que acabou de ir ao Vault.
    aplicar_usuario_scram
    unset senha

    # 3) Tópico. Existente com outro número de partições é divergência a resolver
    # à mão: aumentar partições muda a chave de ordenação, e reduzir não existe.
    log "Criando o tópico $TOPICO (se ainda não existir)"
    kafka_admin kafka-topics.sh \
        --create --if-not-exists --topic "$TOPICO" --partitions "$PARTICOES" --replication-factor 1 \
        --config retention.ms=-1 --config cleanup.policy=delete
    local descricao
    descricao=$(kafka_admin kafka-topics.sh --describe --topic "$TOPICO")
    grep -q "PartitionCount: $PARTICOES" <<<"$descricao" \
        || falha "o tópico $TOPICO existe com número de partições diferente de $PARTICOES"
    kafka_admin kafka-configs.sh --alter --entity-type topics --entity-name "$TOPICO" \
        --add-config retention.ms=-1,cleanup.policy=delete

    # 4) ACL literal: só Write e Describe.
    log "Concedendo Write e Describe em $TOPICO a User:$USUARIO"
    kafka_admin kafka-acls.sh --add --allow-principal "User:$USUARIO" --operation Write --operation Describe --topic "$TOPICO"

    local acls
    acls=$(kafka_admin kafka-acls.sh --list --principal "User:$USUARIO")
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
    fim=$(kafka_admin kafka-get-offsets.sh --topic "$TOPICO" --time -1 | awk -F: '{s+=$3} END{print s+0}')
    inicio=$(kafka_admin kafka-get-offsets.sh --topic "$TOPICO" --time -2 | awk -F: '{s+=$3} END{print s+0}')
    echo $((fim - inicio))
}

# Falha se alguma ACL que alcança o usuário (dele ou do curinga `User:*`), em qualquer
# recurso, padrão ou permissão, fugir de Write e Describe LITERAIS neste tópico. É esta
# conferência, e não uma tentativa de apagar ou alterar o tópico, que prova a ausência
# de Delete, Alter, Read, Create e de ACL prefixada ou com curinga: se a conta tivesse
# permissão demais, a tentativa executaria de verdade na trilha.
conferir_acls() {
    conferir_acls_do_usuario "Write e Describe literais em $TOPICO" \
        "TOPIC|$TOPICO|LITERAL|User:$USUARIO|DESCRIBE|ALLOW" \
        "TOPIC|$TOPICO|LITERAL|User:$USUARIO|WRITE|ALLOW"
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
    kafka_admin kafka-get-offsets.sh \
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

    local descartavel=verificacao_752_negativa
    log "Rodando o cliente temporário (contêiner --rm) com a credencial $USUARIO"
    local resultado
    resultado=$(printf '%s\n' "$senha" | conteiner_usuario_com_roteiro verificar-credencial-registro-acesso.sh \
        "TOPICO=$TOPICO" "PUBLICAR=$publicar" "DESCARTAVEL=$descartavel") \
        || falha "o cliente de verificação terminou com erro"
    unset senha
    echo "$resultado"

    # O tópico descartável não pode sobrar, passe ou não a verificação.
    if kafka_admin kafka-topics.sh --list | grep -qx "$descartavel"; then
        kafka_admin kafka-topics.sh --delete --topic "$descartavel"
        falha "a credencial criou o tópico $descartavel (apagado): tem mais permissão do que deveria"
    fi
    if grep -q 'FALHA' <<<"$resultado"; then
        falha "a credencial do registro de acesso tem mais (ou menos) permissão do que deveria"
    fi

    log "Conferindo o estado do tópico como admin"
    kafka_admin kafka-topics.sh --describe --topic "$TOPICO"
    kafka_admin kafka-configs.sh --describe --entity-type topics --entity-name "$TOPICO"

    if [[ "$publicar" == 1 ]]; then
        # Partição e offset devolvidos pelo broker à própria mensagem de teste.
        local enviado particao offset
        enviado=$(grep 'producer_send_success' <<<"$resultado" | head -n1 || true)
        particao=$(sed -n 's/.*"partition":\([0-9]*\).*/\1/p' <<<"$enviado")
        offset=$(sed -n 's/.*"offset":\([0-9]*\).*/\1/p' <<<"$enviado")
        [[ -n "$particao" && -n "$offset" ]] || falha "o produtor não devolveu partição e offset; nada foi removido"
        # Tópico vazio antes do teste: o offset devolvido tem de ser o fim anterior da partição.
        if [[ "$offset" != "${fim_antes[particao]}" ]]; then
            log "AVISO: offset devolvido ($offset) difere do esperado (${fim_antes[particao]}) na partição $particao; NADA foi removido. Conferir o tópico à mão."
            falha "offset inesperado para o registro de teste"
        fi
        local lido
        lido=$(kafka_admin kafka-console-consumer.sh --topic "$TOPICO" --partition "$particao" --offset "$offset" \
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

case "$acao" in
    provisionar) provisionar ;;
    ca) vault_conectar "$tmpdir"; gravar_ca ;;
    verificar) verificar ;;
    *) falha "uso: $0 [provisionar|ca|verificar]" ;;
esac
