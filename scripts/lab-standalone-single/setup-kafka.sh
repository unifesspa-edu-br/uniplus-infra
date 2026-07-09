#!/usr/bin/env bash
# scripts/lab-standalone-single/setup-kafka.sh
#
# Configura Apache Kafka 4.2.0 (KRaft only) como container Docker gerenciado
# por systemd num host combinado de laboratório (K3s + data services na
# mesma VM), replicando fielmente o padrão do data-host real
# (scripts/bootstrap-standalone.sh, step_data_setup_kafka) — já é single-node
# combined (process.roles=broker,controller), SASL_SSL + SCRAM-SHA-512 +
# StandardAuthorizer conforme ADR-009.
#
# UID/GID: 1000:1000 (appuser, default user da imagem apache/kafka:4.2.0).
#
# Encryption: TLS via cert PEM self-signed estático (10 anos), SAN cobrindo
# DATA_HOST_IP + localhost. Authentication: SCRAM-SHA-512 exclusivo, admin
# embarcada via `kafka-storage.sh format --add-scram` no bootstrap inicial
# (--add-scram só é honrado no format inicial — daí o passo explícito antes
# do primeiro systemctl start). Authorization: StandardAuthorizer,
# fail-closed (allow.everyone.if.no.acl.found=false), super.users=User:admin.
#
# server.properties é gerado como arquivo (não via env KAFKA_*) porque o
# KafkaDockerWrapper da imagem não preserva hyphens em nomes de listener
# (ex.: SCRAM-SHA-512), inviabilizando via env.
#
# Uso:
#   ./setup-kafka.sh [--dry-run]
#
# Variáveis de ambiente:
#   DATA_HOST_IP   IPv4 privado a bindar (default: auto-detectado via `hostname -I`)
#   DATA_BASE      Diretório base dos volumes de dados (default: /var/lib/uniplus)
#
# Pré-requisitos: Docker instalado, usuário com sudo sem senha (ou rodar via sudo).
set -euo pipefail

DRY_RUN=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Uso: $0 [--dry-run]"
            exit 0
            ;;
        *) echo "Opção inválida: $arg" >&2; exit 2 ;;
    esac
done

if [[ -z "${DATA_HOST_IP:-}" ]] && command -v hostname &>/dev/null; then
    DATA_HOST_IP=$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        | head -1)
fi
if [[ -z "${DATA_HOST_IP:-}" ]]; then
    echo "ERRO: não consegui auto-detectar DATA_HOST_IP. Defina explicitamente: DATA_HOST_IP=x.x.x.x $0" >&2
    exit 1
fi

DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
CREDS_FILE="$DATA_BASE/kafka/.bootstrap-creds"
CERTS_DIR="/etc/uniplus-kafka/certs"
CONFIG_DIR="/etc/uniplus-kafka/config"
SERVER_PROPS="$CONFIG_DIR/server.properties"
ADMIN_PROPS="$DATA_BASE/kafka/admin.properties"
ENV_FILE="/etc/uniplus-kafka.env"
UNIT_FILE="/etc/systemd/system/uniplus-kafka.service"
KAFKA_IMAGE="apache/kafka:4.2.0"

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[ OK ] $*"; }
log_warn()    { echo "[WARN] $*" >&2; }
log_error()   { echo "[ERROR] $*" >&2; }

run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        bash -c "$*"
    fi
}

log_info "DATA_HOST_IP=$DATA_HOST_IP DATA_BASE=$DATA_BASE DRY_RUN=$DRY_RUN"

# data dir 1000:1000 (appuser do container); certs_dir/config_dir 755
# root:root — uid 1000 precisa traverse para abrir os PEMs e o
# server.properties (arquivos individuais têm mode próprio mais restrito).
run "sudo mkdir -p $DATA_BASE/kafka/data $CERTS_DIR $CONFIG_DIR"
run "sudo chown 1000:1000 $DATA_BASE/kafka/data"
run "sudo chmod 750 $DATA_BASE/kafka/data"
run "sudo chown root:root $CERTS_DIR $CONFIG_DIR"
run "sudo chmod 755 $CERTS_DIR $CONFIG_DIR"

already_initialized=false
if ! $DRY_RUN && sudo test -f "$DATA_BASE/kafka/data/meta.properties" 2>/dev/null; then
    already_initialized=true
fi

# ---- Decisão 1: .bootstrap-creds (cluster_id + admin_pw) ----
if sudo test -f "$CREDS_FILE" 2>/dev/null; then
    if ! sudo grep -q '^admin_pw=' "$CREDS_FILE" 2>/dev/null; then
        log_error "$CREDS_FILE existe mas não contém admin_pw."
        exit 1
    fi
    log_success "Bootstrap creds Kafka já existentes (cluster_id + admin_pw) — preservando."
elif $DRY_RUN; then
    log_warn "Dry-run: cluster_id + admin_pw seriam gerados em $CREDS_FILE"
elif $already_initialized; then
    log_error "$CREDS_FILE ausente, mas $DATA_BASE/kafka/data/meta.properties já existe."
    log_error "Storage formatado mas creds ausentes — mismatch, não prossigo automaticamente."
    exit 1
else
    log_info "Gerando cluster_id + admin SCRAM-SHA-512 password..."
    cluster_id=$(sudo docker run --rm --entrypoint /opt/kafka/bin/kafka-storage.sh \
        "$KAFKA_IMAGE" random-uuid 2>/dev/null | tr -d '\r\n')
    if [[ -z "$cluster_id" ]]; then
        log_error "Falha ao gerar cluster_id via kafka-storage.sh."
        exit 1
    fi
    admin_pw=$(openssl rand -hex 32)
    sudo tee "$CREDS_FILE" >/dev/null <<EOF
cluster_id=$cluster_id
admin_pw=$admin_pw
EOF
    sudo chown root:root "$CREDS_FILE"
    sudo chmod 600 "$CREDS_FILE"
    unset cluster_id admin_pw
    log_warn "cluster_id + admin_pw gerados em $CREDS_FILE. Custódia obrigatória antes de descartar."
fi

# ---- Decisão 2: certs PEM self-signed (10 anos) ----
# Só considera "completo" com os 4 arquivos presentes — um bootstrap
# interrompido no meio poderia deixar server.pem ausente e o broker falharia
# silenciosamente no próximo start.
if sudo test -f "$CERTS_DIR/server.crt" 2>/dev/null && \
   sudo test -f "$CERTS_DIR/server.key" 2>/dev/null && \
   sudo test -f "$CERTS_DIR/ca.crt" 2>/dev/null && \
   sudo test -f "$CERTS_DIR/server.pem" 2>/dev/null; then
    log_success "Certs Kafka completos (crt/key/ca/pem) — preservando."
elif $DRY_RUN; then
    log_warn "Dry-run: cert self-signed seria gerado em $CERTS_DIR/"
else
    log_info "Gerando cert self-signed PEM (10 anos, SAN: $DATA_HOST_IP + localhost)..."
    ssl_cnf="$CERTS_DIR/openssl.cnf"
    sudo tee "$ssl_cnf" >/dev/null <<CNF
[req]
distinguished_name = req_distinguished_name
prompt = no
req_extensions = v3_req

[req_distinguished_name]
CN = uniplus-kafka.lab

[v3_req]
basicConstraints = CA:TRUE
keyUsage = digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = uniplus-kafka.lab
DNS.2 = localhost
IP.1 = $DATA_HOST_IP
IP.2 = 127.0.0.1
CNF
    sudo openssl req -x509 -newkey rsa:2048 \
        -keyout "$CERTS_DIR/server.key" \
        -out "$CERTS_DIR/server.crt" \
        -days 3650 -nodes \
        -config "$ssl_cnf" \
        -extensions v3_req >/dev/null 2>&1
    sudo cp "$CERTS_DIR/server.crt" "$CERTS_DIR/ca.crt"
    # PEM keystore = cert + key concatenados (KIP-651) — ssl.keystore.key.location
    # não é propriedade válida do Kafka 4.x.
    sudo bash -c "cat $CERTS_DIR/server.crt $CERTS_DIR/server.key > $CERTS_DIR/server.pem"
    sudo chown 1000:1000 "$CERTS_DIR/server.crt" "$CERTS_DIR/server.key" \
                          "$CERTS_DIR/ca.crt" "$CERTS_DIR/server.pem"
    sudo chmod 644 "$CERTS_DIR/server.crt" "$CERTS_DIR/ca.crt"
    sudo chmod 600 "$CERTS_DIR/server.key" "$CERTS_DIR/server.pem"
    sudo rm -f "$ssl_cnf"
    log_warn "Cert self-signed gerado em $CERTS_DIR/server.{crt,pem} (validade 10 anos)."
fi

# ---- Decisão 3: format inicial com --add-scram ----
# --add-scram só é honrado no format inicial. Roda ANTES do systemctl start
# na 1ª execução, em container ad-hoc; runs subsequentes veem storage já
# formatado (meta.properties presente) e pulam este passo.
if ! $DRY_RUN && ! $already_initialized && sudo test -f "$CREDS_FILE"; then
    log_info "Format do storage com --add-scram (admin SCRAM-SHA-512 embarcada)..."
    cluster_id_init=$(sudo grep '^cluster_id=' "$CREDS_FILE" | cut -d= -f2)
    admin_pw_init=$(sudo grep '^admin_pw=' "$CREDS_FILE" | cut -d= -f2)

    fmt_props=$(sudo mktemp)
    sudo tee "$fmt_props" >/dev/null <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@$DATA_HOST_IP:9093
listeners=SASL_SSL://$DATA_HOST_IP:9092,CONTROLLER://$DATA_HOST_IP:9093
advertised.listeners=SASL_SSL://$DATA_HOST_IP:9092
controller.listener.names=CONTROLLER
inter.broker.listener.name=SASL_SSL
listener.security.protocol.map=CONTROLLER:SASL_SSL,SASL_SSL:SASL_SSL
log.dirs=/var/lib/kafka/data
EOF
    sudo chmod 644 "$fmt_props"

    if ! sudo docker run --rm \
        -v "$DATA_BASE/kafka/data:/var/lib/kafka/data" \
        -v "$fmt_props:/opt/kafka/config/format.properties:ro" \
        --entrypoint /opt/kafka/bin/kafka-storage.sh \
        "$KAFKA_IMAGE" \
        format --config /opt/kafka/config/format.properties \
               --cluster-id "$cluster_id_init" \
               --add-scram "SCRAM-SHA-512=[name=admin,password=$admin_pw_init]" \
               --ignore-formatted >/dev/null 2>&1; then
        log_error "Format do storage falhou. Re-rode manualmente em verbose para diagnosticar."
        sudo rm -f "$fmt_props"
        exit 1
    fi
    sudo rm -f "$fmt_props"
    unset cluster_id_init admin_pw_init
    log_success "Storage formatado com admin SCRAM-SHA-512 embarcada."
fi

# ---- Decisão 4: server.properties (sempre re-aplicado) ----
# Contém a senha SCRAM em cleartext (Kafka 4.x exige JAAS inline por
# listener, sem mecanismo file-based). Mode 600 chown 1000:1000.
if $DRY_RUN; then
    log_warn "Dry-run: server.properties seria escrito em $SERVER_PROPS"
else
    admin_pw_curr=$(sudo grep '^admin_pw=' "$CREDS_FILE" | cut -d= -f2)
    if [[ -z "$admin_pw_curr" ]]; then
        log_error "admin_pw vazio em $CREDS_FILE. Abortando."
        exit 1
    fi
    sudo tee "$SERVER_PROPS" >/dev/null <<EOF
# === KRaft topology (single-node combined) ===
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@$DATA_HOST_IP:9093
listeners=SASL_SSL://$DATA_HOST_IP:9092,CONTROLLER://$DATA_HOST_IP:9093
advertised.listeners=SASL_SSL://$DATA_HOST_IP:9092
controller.listener.names=CONTROLLER
inter.broker.listener.name=SASL_SSL
listener.security.protocol.map=CONTROLLER:SASL_SSL,SASL_SSL:SASL_SSL

# === Storage ===
log.dirs=/var/lib/kafka/data
auto.create.topics.enable=false

# === Replication factor 1 (single-node, sem replicação) ===
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1

# === SASL/SCRAM-SHA-512 (admin embarcada via --add-scram no format) ===
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
sasl.mechanism.controller.protocol=SCRAM-SHA-512
listener.name.sasl_ssl.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="$admin_pw_curr";
listener.name.controller.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="$admin_pw_curr";

# === TLS (PEM keystore + truststore; self-signed = ca = cert) ===
ssl.keystore.type=PEM
ssl.keystore.location=/etc/kafka/secrets/server.pem
ssl.truststore.type=PEM
ssl.truststore.location=/etc/kafka/secrets/ca.crt
ssl.client.auth=none

# === StandardAuthorizer (KRaft-native; fail-closed) ===
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
super.users=User:admin
allow.everyone.if.no.acl.found=false
EOF
    sudo chown 1000:1000 "$SERVER_PROPS"
    sudo chmod 600 "$SERVER_PROPS"
    unset admin_pw_curr
fi

# ---- Decisão 5: admin.properties (CLI tools como admin) ----
if ! $DRY_RUN; then
    admin_pw_props=$(sudo grep '^admin_pw=' "$CREDS_FILE" | cut -d= -f2)
    sudo tee "$ADMIN_PROPS" >/dev/null <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="$admin_pw_props";
ssl.truststore.type=PEM
ssl.truststore.location=$CERTS_DIR/ca.crt
ssl.endpoint.identification.algorithm=
EOF
    sudo chown 1000:1000 "$ADMIN_PROPS"
    sudo chmod 600 "$ADMIN_PROPS"
    unset admin_pw_props
fi

# ---- Decisão 6: EnvironmentFile (mínimo — CLUSTER_ID + JVM heap) ----
if $DRY_RUN; then
    log_warn "Dry-run: $ENV_FILE seria escrito"
else
    cluster_id_env=$(sudo grep '^cluster_id=' "$CREDS_FILE" | cut -d= -f2)
    sudo tee "$ENV_FILE" >/dev/null <<EOF
CLUSTER_ID=$cluster_id_env
KAFKA_HEAP_OPTS="-Xmx1g -Xms1g"
EOF
    sudo chown root:root "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"
    unset cluster_id_env
fi

# ---- Decisão 7: systemd unit ----
if $DRY_RUN; then
    log_warn "Dry-run: unit systemd seria escrito em $UNIT_FILE"
else
    sudo tee "$UNIT_FILE" >/dev/null <<UNIT
[Unit]
Description=Uni+ Apache Kafka 4.2.0 KRaft (SASL_SSL + SCRAM-SHA-512, lab standalone-single)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=180
EnvironmentFile=$ENV_FILE

ExecStartPre=-/usr/bin/docker rm -f uniplus-kafka
ExecStart=/usr/bin/docker run --rm --name uniplus-kafka \\
  --network host \\
  -e CLUSTER_ID \\
  -e KAFKA_HEAP_OPTS \\
  -v $DATA_BASE/kafka/data:/var/lib/kafka/data \\
  -v $CONFIG_DIR:/mnt/shared/config:ro \\
  -v $CERTS_DIR:/etc/kafka/secrets:ro \\
  $KAFKA_IMAGE

ExecStop=/usr/bin/docker stop -t 30 uniplus-kafka

[Install]
WantedBy=multi-user.target
UNIT
fi

run "sudo systemctl daemon-reload"
run "sudo systemctl enable uniplus-kafka"

if $DRY_RUN; then
    log_warn "Dry-run: systemctl start uniplus-kafka + SASL_SSL broker-api-versions probe"
elif sudo systemctl is-active --quiet uniplus-kafka; then
    log_success "uniplus-kafka já ativo — preservando state (sem restart)."
else
    sudo systemctl start uniplus-kafka
    log_info "Aguardando Kafka aceitar conexões SASL_SSL (cold start ~30-90s)..."
    attempts=0
    until sudo docker run --rm --network host \
            -v "$ADMIN_PROPS:/tmp/admin.properties:ro" \
            -v "$CERTS_DIR/ca.crt:$CERTS_DIR/ca.crt:ro" \
            --entrypoint /opt/kafka/bin/kafka-broker-api-versions.sh \
            "$KAFKA_IMAGE" \
            --bootstrap-server "$DATA_HOST_IP:9092" \
            --command-config /tmp/admin.properties &>/dev/null; do
        attempts=$(( attempts + 1 ))
        if (( attempts >= 36 )); then
            log_error "Kafka SASL_SSL não respondeu broker-api-versions em 180s."
            log_error "Ver: sudo journalctl -u uniplus-kafka -n 100"
            exit 1
        fi
        sleep 5
    done
    log_success "uniplus-kafka ativo + SASL_SSL broker-api-versions OK."
fi
