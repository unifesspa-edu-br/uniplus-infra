#!/usr/bin/env bash
# Provisiona, no Kafka, a credencial própria do Kafka UI (AKHQ), que nunca usa a
# do administrador: `admin` é super usuário e passa por cima de qualquer ACL, o
# que tornaria inútil negar a leitura de um tópico à interface.
#
#   - usuário SCRAM `uniplus-kafka-ui-svc`, com senha gerada aqui e guardada só no
#     Vault (`plataforma/kafka/kafka-ui`, chaves `username`, `password` e `ca_cert`),
#     de onde o ExternalSecret do chart `kafka-ui` a lê. O CA é certificado público,
#     lido do broker, e vai ao Vault sem passar por argv de comando externo;
#   - ACLs mínimas, todas literais:
#       cluster    Describe, DescribeConfigs   (nós, configuração do broker e ACLs)
#       tópicos    Describe, DescribeConfigs   (listar, partições, offsets, configuração)
#       tópicos    Read                        (conteúdo das mensagens)
#       grupos     Describe                    (listar grupos e atraso)
#       DENY Read em `autorizacao_registros_de_acesso`: no StandardAuthorizer a
#       negação prevalece sobre qualquer permissão, então nenhuma ACL de leitura
#       concedida depois reabre a trilha de acessos;
#   - nada de Write, Create, Delete nem Alter: criar, apagar ou alterar tópicos
#     continua com a credencial `admin`, pelos scripts da VM de infraestrutura.
#
# `Read` em grupo de consumo NÃO é concedido: a interface lê as mensagens por
# atribuição manual de partição, sem entrar em grupo nem confirmar offsets, e
# `verificar` prova esse caminho. Só `Describe` em grupo, para listá-los.
#
# Uso (na VM de infraestrutura, com o ROOT_TOKEN do Vault no ambiente ou pedido no terminal):
#   provisionar-kafka-ui.sh [--dry-run] [provisionar]   cria o que falta
#   provisionar-kafka-ui.sh [--dry-run] verificar       prova o que a credencial permite e recusa
#
# `provisionar` é idempotente: a senha existente no Vault é reaproveitada; o
# usuário e as ACLs são reaplicados e o CA é regravado se mudou. `verificar` cria um
# tópico de teste com uma mensagem (recusa seguir se ele já existir), roda um contêiner
# descartável (`--rm`) com a credencial do Kafka UI e apaga o tópico ao fim, mesmo se a
# verificação falhar ou for interrompida. A senha entra nos contêineres por stdin: não
# aparece em argv do `docker run`, em arquivo nem na saída.
#
# Variáveis (as de lib-comum.sh valem aqui):
#   INFRA_FQDN    nome do broker, validado pelo certificado
#   BOOTSTRAP     default $INFRA_FQDN:9092
#   KAFKA_IMAGE   default apache/kafka:4.2.0
#   CA_CRT        CA do broker, default /etc/uniplus-kafka/certs/ca.crt
#   VAULT_URL     ver lib-vault.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

KAFKA_IMAGE="${KAFKA_IMAGE:-apache/kafka:4.2.0}"
BOOTSTRAP="${BOOTSTRAP:-$INFRA_FQDN:9092}"
USUARIO="uniplus-kafka-ui-svc"
TOPICO_PROTEGIDO="autorizacao_registros_de_acesso"
TOPICO_LEITURA="verificacao_kafka_ui_leitura"
MENSAGEM_DE_TESTE="verificacao-kafka-ui"
VAULT_CAMINHO="plataforma/kafka/kafka-ui"
ADMIN_PROPERTIES="$DATA_BASE/kafka/admin.properties"
CA_CRT="${CA_CRT:-/etc/uniplus-kafka/certs/ca.crt}"

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
    echo "[DRY-RUN] $acao: usuário SCRAM $USUARIO em $BOOTSTRAP, credencial em $VAULT_CAMINHO"
    if [[ "$acao" == provisionar ]]; then
        echo "[DRY-RUN] Describe e DescribeConfigs no cluster; Describe, DescribeConfigs e Read em todos os tópicos;"
        echo "[DRY-RUN] Describe em todos os grupos; DENY Read em $TOPICO_PROTEGIDO"
    else
        echo "[DRY-RUN] conferiria as ACLs e, com a credencial, o que é permitido e o que é recusado"
    fi
    exit 0
fi

# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"
# shellcheck source=lib-kafka.sh
source "$SCRIPT_DIR/lib-kafka.sh"
command -v docker >/dev/null || falha "docker ausente"
sudo test -r "$ADMIN_PROPERTIES" || falha "$ADMIN_PROPERTIES ausente ou ilegível"

kafka_acls() { kafka_admin kafka-acls.sh "$@"; }

# Garante o segredo no Vault: gera a senha uma vez e mantém o CA do broker em dia.
# A senha é gravada ANTES de ser aplicada no broker, para nunca existir um usuário
# cuja senha ninguém guardou. O KV v2 troca o segredo inteiro a cada gravação, então
# usuário, senha e CA vão juntos.
garantir_credencial_no_vault() {
    local ca senha
    ca=$(sudo cat "$CA_CRT")
    openssl x509 -noout <<<"$ca" 2>/dev/null || falha "$CA_CRT não é um certificado PEM válido"
    if vault_existe "$VAULT_CAMINHO"; then
        senha=$(senha_do_vault)
        if [[ "$(vault_get "$VAULT_CAMINHO" ca_cert || true)" == "$ca" \
            && "$(vault_get "$VAULT_CAMINHO" username || true)" == "$USUARIO" ]]; then
            log_success "$VAULT_CAMINHO já está no Vault com o CA atual; senha reaproveitada."
            return 0
        fi
        log_info "Atualizando usuário e CA em $VAULT_CAMINHO (senha reaproveitada)"
    else
        log_info "Gerando a senha de $USUARIO e gravando no Vault ($VAULT_CAMINHO)"
        senha=$(openssl rand -hex 32)
    fi
    vault_put "$VAULT_CAMINHO" "username=$USUARIO" "password=$senha" "ca_cert=$ca"
    [[ "$(senha_do_vault)" == "$senha" ]] || falha "a senha lida do Vault difere da gravada"
    [[ "$(vault_get "$VAULT_CAMINHO" ca_cert)" == "$ca" ]] || falha "o CA lido do Vault difere do gravado"
}

# A negação vem primeiro: nunca há instante em que `Read` em todos os tópicos esteja
# concedido sem a recusa da trilha de acessos.
aplicar_acls() {
    log_info "Negando Read em $TOPICO_PROTEGIDO a User:$USUARIO"
    kafka_acls --add --deny-principal "User:$USUARIO" --operation Read --topic "$TOPICO_PROTEGIDO"
    log_info "Concedendo Describe e DescribeConfigs no cluster"
    kafka_acls --add --allow-principal "User:$USUARIO" \
        --operation Describe --operation DescribeConfigs --cluster
    log_info "Concedendo Describe, DescribeConfigs e Read em todos os tópicos"
    kafka_acls --add --allow-principal "User:$USUARIO" \
        --operation Describe --operation DescribeConfigs --operation Read --topic '*'
    log_info "Concedendo Describe em todos os grupos"
    kafka_acls --add --allow-principal "User:$USUARIO" --operation Describe --group '*'
}

conferir_acls() {
    conferir_acls_do_usuario "conjunto mínimo de leitura e descrição" \
        "CLUSTER|kafka-cluster|LITERAL|User:$USUARIO|DESCRIBE|ALLOW" \
        "CLUSTER|kafka-cluster|LITERAL|User:$USUARIO|DESCRIBE_CONFIGS|ALLOW" \
        "TOPIC|*|LITERAL|User:$USUARIO|DESCRIBE|ALLOW" \
        "TOPIC|*|LITERAL|User:$USUARIO|DESCRIBE_CONFIGS|ALLOW" \
        "TOPIC|*|LITERAL|User:$USUARIO|READ|ALLOW" \
        "GROUP|*|LITERAL|User:$USUARIO|DESCRIBE|ALLOW" \
        "TOPIC|$TOPICO_PROTEGIDO|LITERAL|User:$USUARIO|READ|DENY"
    log_success "ACLs conferidas: só leitura e descrição; Read negado em $TOPICO_PROTEGIDO."
}

provisionar() {
    garantir_credencial_no_vault
    aplicar_usuario_scram
    aplicar_acls
    conferir_acls
    log_success "Provisionamento concluído. Rodar 'verificar' em seguida."
}

# Só este script apaga o tópico de teste, e só depois de ter sido ele a criá-lo: um
# tópico com esse nome que já exista não é tocado, porque não há como saber se é sobra
# de uma execução interrompida ou dado de alguém.
TOPICO_DE_TESTE_CRIADO=false

# Tópico de teste com uma mensagem, que a credencial deve conseguir ler.
criar_topico_de_leitura() {
    local topicos
    topicos=$(kafka_admin kafka-topics.sh --list)
    if grep -qx "$TOPICO_LEITURA" <<<"$topicos"; then
        falha "o tópico $TOPICO_LEITURA já existe; conferir se é sobra de uma verificação interrompida e apagá-lo à mão"
    fi
    kafka_admin kafka-topics.sh --create --topic "$TOPICO_LEITURA" --partitions 1 --replication-factor 1
    TOPICO_DE_TESTE_CRIADO=true
    printf '%s\n' "$MENSAGEM_DE_TESTE" | kafka_admin kafka-console-producer.sh --topic "$TOPICO_LEITURA"
}

remover_topico_de_teste() {
    [[ "$TOPICO_DE_TESTE_CRIADO" == true ]] || return 0
    # `|| return`: chamada de dentro de `||` (no trap), o `set -e` não vale na função.
    kafka_admin kafka-topics.sh --delete --topic "$TOPICO_LEITURA" || return
    TOPICO_DE_TESTE_CRIADO=false
}

# Saída do `verificar` por fim normal, erro (`set -e`) ou sinal: apaga o tópico de teste
# se foi este script que o criou (e, se a exclusão falhar, avisa), preserva o código de
# saída e limpa o provisionamento.
encerrar_verificacao() {
    local status=$?
    trap - EXIT
    remover_topico_de_teste || log_warn "não consegui apagar $TOPICO_LEITURA; apagá-lo à mão"
    limpar_provisionamento
    exit "$status"
}

verificar() {
    local senha resultado status=0
    trap encerrar_verificacao EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    senha=$(senha_do_vault)
    conferir_acls
    criar_topico_de_leitura
    log_info "Rodando o cliente temporário (contêiner --rm) com a credencial $USUARIO"
    resultado=$(printf '%s\n' "$senha" | conteiner_usuario_com_roteiro verificar-credencial-kafka-ui.sh \
        "TOPICO_PROTEGIDO=$TOPICO_PROTEGIDO" "TOPICO_LEITURA=$TOPICO_LEITURA" \
        "MENSAGEM_DE_TESTE=$MENSAGEM_DE_TESTE") || status=$?
    unset senha
    remover_topico_de_teste
    echo "$resultado"
    [[ "$status" -eq 0 ]] || falha "o cliente de verificação terminou com erro ($status)"
    if grep -q 'FALHA' <<<"$resultado"; then
        falha "a credencial do Kafka UI tem mais (ou menos) permissão do que deveria"
    fi
    log_success "Verificação concluída: a credencial lê e descreve, e não lê $TOPICO_PROTEGIDO."
}

preparar_provisionamento
case "$acao" in
    provisionar) provisionar ;;
    verificar) verificar ;;
    *) falha "uso: $0 [provisionar|verificar]" ;;
esac
