#!/usr/bin/env bash
# RabbitMQ da VM de infraestrutura de produção: container Docker gerenciado por
# systemd, só com AMQPS (5671) e gerência HTTPS (15671). O vhost e os usuários
# da API e do verificador são criados por provisionar-rabbitmq.sh, que lê as
# senhas do Vault.

RABBITMQ_IMAGE="rabbitmq:4.1.4-management-alpine"
RABBITMQ_UID=100
RABBITMQ_GID=101
RABBITMQ_TLS_DIR="$DATA_BASE/rabbitmq/tls"
RABBITMQ_CONFIG_DIR="$DATA_BASE/rabbitmq/config"
RABBITMQ_MEMORY_BYTES=2147483648

conf_rabbitmq() {
    cat <<CONF
listeners.tcp = none
listeners.ssl.default = 5671
management.ssl.port = 15671
ssl_options.certfile = /etc/rabbitmq-tls/public.crt
ssl_options.keyfile = /etc/rabbitmq-tls/private.key
ssl_options.versions.1 = tlsv1.3
ssl_options.versions.2 = tlsv1.2
management.ssl.certfile = /etc/rabbitmq-tls/public.crt
management.ssl.keyfile = /etc/rabbitmq-tls/private.key
default_queue_type = quorum
disk_free_limit.absolute = 1GB
total_memory_available_override_value = ${RABBITMQ_MEMORY_BYTES}
vm_memory_high_watermark.relative = 0.6
prometheus.return_per_object_metrics = false
CONF
}

unidade_rabbitmq() {
    cat <<UNIT
[Unit]
Description=Uni+ RabbitMQ (producao)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=300
LoadCredential=admin-password:/etc/credstore/uniplus-rabbitmq-admin-password
ExecStartPre=-/usr/bin/docker rm -f uniplus-rabbitmq
ExecStart=/usr/bin/docker run --rm --name uniplus-rabbitmq \\
  --network host \\
  --hostname ${INFRA_FQDN} \\
  --memory ${RABBITMQ_MEMORY_BYTES} \\
  -e RABBITMQ_DEFAULT_USER=rabbitmq-admin \\
  -e RABBITMQ_DEFAULT_PASS_FILE=/run/secrets/admin-password \\
  -v \${CREDENTIALS_DIRECTORY}/admin-password:/run/secrets/admin-password:ro \\
  -v ${DATA_BASE}/rabbitmq/data:/var/lib/rabbitmq \\
  -v ${RABBITMQ_TLS_DIR}:/etc/rabbitmq-tls:ro \\
  -v ${RABBITMQ_CONFIG_DIR}/10-uniplus.conf:/etc/rabbitmq/conf.d/10-uniplus.conf:ro \\
  ${RABBITMQ_IMAGE}
ExecStop=/usr/bin/docker stop -t 60 uniplus-rabbitmq

[Install]
WantedBy=multi-user.target
UNIT
}

step_rabbitmq() {
    log_info "Configurando RabbitMQ com AMQPS..."
    local creds_file="$DATA_BASE/rabbitmq/.bootstrap-creds"

    run "sudo mkdir -p $DATA_BASE/rabbitmq/data"
    run "sudo chown $RABBITMQ_UID:$RABBITMQ_GID $DATA_BASE/rabbitmq/data"
    run "sudo install -d -m 755 $RABBITMQ_CONFIG_DIR"
    conf_rabbitmq | gravar_arquivo_root "$RABBITMQ_CONFIG_DIR/10-uniplus.conf" 644
    instalar_par_tls "$RABBITMQ_TLS_DIR" "$RABBITMQ_UID"
    garantir_credencial "$creds_file" admin_pw

    if $DRY_RUN; then
        echo "[DRY-RUN] copiaria admin_pw para /etc/credstore/uniplus-rabbitmq-admin-password (modo 400)"
    else
        ler_credencial "$creds_file" admin_pw | tr -d '\n' \
            | gravar_arquivo_root /etc/credstore/uniplus-rabbitmq-admin-password 400
    fi
    unidade_rabbitmq | gravar_arquivo_root /etc/systemd/system/uniplus-rabbitmq.service 644

    run "sudo systemctl daemon-reload"
    run "sudo systemctl enable uniplus-rabbitmq"
    if $DRY_RUN; then
        echo "[DRY-RUN] systemctl start uniplus-rabbitmq"
    elif sudo systemctl is-active --quiet uniplus-rabbitmq; then
        log_success "uniplus-rabbitmq já ativo; a configuração nova vale no próximo restart."
    else
        sudo systemctl start uniplus-rabbitmq
    fi
}
