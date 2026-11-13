#!/bin/sh
# Roda DENTRO do contêiner descartável do Kafka, pelo provisionar-kafka.sh. Prova, com
# a credencial do registro de acesso, o que o broker permite e o que recusa. A senha vem
# na entrada padrão e só é escrita no /tmp do contêiner, que some com ele. Nada aqui
# apaga ou altera o tópico real.
#
# Cada falha da verificação vem numa linha com FALHA; o chamador falha se houver alguma.
#
# Variáveis: BOOTSTRAP, USUARIO, TOPICO (trilha), PUBLICAR (1 grava uma mensagem de teste) e
# DESCARTAVEL (nome do tópico que a credencial não pode conseguir criar).
set -u

umask 077
read -r SENHA_DO_USUARIO
CLIENTE=/tmp/cliente.properties
# O produtor idempotente exige `retries` diferente de zero, e o produtor verificável
# parte de zero: sem a linha `retries`, ele termina com ConfigException.
cat >"$CLIENTE" <<PROP
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="$USUARIO" password="$SENHA_DO_USUARIO";
ssl.truststore.type=PEM
ssl.truststore.location=/etc/uniplus-kafka/certs/ca.crt
ssl.endpoint.identification.algorithm=
enable.idempotence=true
retries=2147483647
PROP
unset SENHA_DO_USUARIO
# Desde o Kafka 4.2 (KIP-1147) os clientes de console e o produtor verificável aceitam
# `--command-config`; a imagem é a fixada em instalar-kafka.sh (apache/kafka:4.2.0).
BIN=/opt/kafka/bin
SAIDA=/tmp/saida

# Os clientes de console saem com 0 mesmo quando o broker recusa: a recusa se reconhece
# pela exceção de autorização na saída, sem o registro de teste ("752.0").
recusado() {
    if grep -qi "authorization" "$SAIDA" && ! grep -q "752\.0" "$SAIDA"; then
        echo "$1: RECUSADO pelo broker (autorização)"
    else
        echo "$1: NAO RECUSADO <<<<<< FALHA"
        tail -n 5 "$SAIDA"
    fi
}

if [ "$PUBLICAR" = 1 ]; then
    # O produtor verificável devolve partição e offset gravados no broker.
    "$BIN/kafka-verifiable-producer.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
        --topic "$TOPICO" --max-messages 1 --acks -1 --value-prefix 752 >"$SAIDA" 2>&1
    status=$?
    echo "publicar: rc=$status"
    grep "producer_send_success" "$SAIDA" | sed "s/^/produce: /"
    if [ "$status" -ne 0 ] || ! grep -q "producer_send_success" "$SAIDA"; then
        echo "publicar: a mensagem de teste não foi gravada <<<<<< FALHA"
        tail -n 5 "$SAIDA"
    fi
fi

# Describe: listar offsets pede só Describe no tópico (kafka-topics --describe pede também DescribeConfigs).
"$BIN/kafka-get-offsets.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO" --time -1 >"$SAIDA" 2>&1
status=$?
echo "descrever (Describe): rc=$status"
[ "$status" -ne 0 ] && echo "descrever: FALHA"

"$BIN/kafka-console-consumer.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO" --from-beginning --max-messages 1 --timeout-ms 15000 \
    --group verificacao-752 >"$SAIDA" 2>&1
recusado "ler (Read)"

# Sem assinatura de grupo (atribuição manual), a recusa vem do Read no próprio tópico.
"$BIN/kafka-console-consumer.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --topic "$TOPICO" --partition 0 --offset earliest --max-messages 1 \
    --timeout-ms 15000 >"$SAIDA" 2>&1
recusado "ler o tópico sem grupo (Read)"

# Tópico descartável: se a criação passar, o chamador o apaga e a verificação falha.
"$BIN/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" --command-config "$CLIENTE" \
    --create --topic "$DESCARTAVEL" --partitions 1 --replication-factor 1 >"$SAIDA" 2>&1
recusado "criar outro tópico (Create)"
