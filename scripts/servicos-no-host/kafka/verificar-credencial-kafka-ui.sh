#!/bin/sh
# Roda DENTRO do contêiner descartável do Kafka, pelo provisionar-kafka-ui.sh.
# Prova, com a credencial do Kafka UI, o que o broker permite e o que recusa. A
# senha vem na entrada padrão e só é escrita no /tmp do contêiner, que some com ele.
#
# Cada linha de resultado termina em OK ou em FALHA; o chamador falha se houver FALHA.
#
# Variáveis: BOOTSTRAP, USUARIO, TOPICO_PROTEGIDO (trilha de acessos), TOPICO_LEITURA
# (tópico de teste com uma mensagem, criado pelo chamador) e MENSAGEM_DE_TESTE.
set -u

umask 077
read -r SENHA_DO_USUARIO
CLIENTE=/tmp/cliente.properties
cat >"$CLIENTE" <<PROP
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$USUARIO" password="$SENHA_DO_USUARIO";
ssl.truststore.type=PEM
ssl.truststore.location=/etc/uniplus-kafka/certs/ca.crt
ssl.endpoint.identification.algorithm=
PROP
unset SENHA_DO_USUARIO
# Desde o Kafka 4.2 (KIP-1147) os clientes de console e o produtor verificável aceitam
# `--command-config`; a imagem é a fixada em instalar-kafka.sh (apache/kafka:4.2.0).
BIN=/opt/kafka/bin
SAIDA=/tmp/saida

# Os clientes de console saem com 0 mesmo quando o broker recusa: a recusa se
# reconhece pela exceção de autorização na saída.
recusada() {
    if grep -qi "authorization" "$SAIDA"; then
        echo "$1: recusado pelo broker (autorização): OK"
    else
        echo "$1: NÃO foi recusado: FALHA"
        tail -n 5 "$SAIDA"
    fi
}

# $1 = nome, $2 = código de saída do comando. Só conta como permitido se o comando
# terminou bem e sem exceção de autorização.
permitida() {
    if [ "$2" -ne 0 ] || grep -qi "authorization" "$SAIDA"; then
        echo "$1: recusado ou com erro, mas devia ser permitido: FALHA"
        tail -n 5 "$SAIDA"
    else
        echo "$1: permitido: OK"
    fi
}

"$BIN/kafka-acls.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --list >"$SAIDA" 2>&1
permitida "descrever o cluster e as ACLs (Describe no cluster)" $?

"$BIN/kafka-configs.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --describe --entity-type topics --entity-name "$TOPICO_PROTEGIDO" >"$SAIDA" 2>&1
permitida "descrever a configuração da trilha (DescribeConfigs no tópico)" $?

"$BIN/kafka-get-offsets.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO_PROTEGIDO" --time -1 >"$SAIDA" 2>&1
permitida "ver os offsets da trilha (Describe no tópico)" $?

"$BIN/kafka-consumer-groups.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --list >"$SAIDA" 2>&1
permitida "listar grupos de consumo (Describe em grupo)" $?

# Atribuição manual de partição, sem grupo: é como a interface lê as mensagens.
"$BIN/kafka-console-consumer.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO_LEITURA" --partition 0 --offset earliest --max-messages 1 \
    --timeout-ms 20000 >"$SAIDA" 2>&1
if grep -qx "$MENSAGEM_DE_TESTE" "$SAIDA"; then
    echo "ler outro tópico sem grupo (Read no tópico): lido: OK"
else
    echo "ler outro tópico sem grupo (Read no tópico): mensagem não lida: FALHA"
    tail -n 5 "$SAIDA"
fi

"$BIN/kafka-console-consumer.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO_PROTEGIDO" --partition 0 --offset earliest --max-messages 1 \
    --timeout-ms 20000 >"$SAIDA" 2>&1
recusada "ler a trilha sem grupo (Read negado)"

"$BIN/kafka-console-consumer.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO_PROTEGIDO" --from-beginning --max-messages 1 --timeout-ms 20000 \
    --group verificacao-kafka-ui >"$SAIDA" 2>&1
recusada "ler a trilha com grupo (Read negado)"

printf '%s\n' "$MENSAGEM_DE_TESTE" | "$BIN/kafka-console-producer.sh" \
    --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO_LEITURA" >"$SAIDA" 2>&1
recusada "gravar mensagem (sem Write)"

"$BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --create --topic verificacao_kafka_ui_criacao --partitions 1 --replication-factor 1 \
    >"$SAIDA" 2>&1
recusada "criar tópico (sem Create)"

"$BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --delete --topic "$TOPICO_LEITURA" >"$SAIDA" 2>&1
recusada "apagar tópico (sem Delete)"
