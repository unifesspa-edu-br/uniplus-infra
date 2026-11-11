#!/usr/bin/env bash
# PostgreSQL 18 + PostGIS da VM de infraestrutura de produção. Carregado com
# `source` por bootstrap-infra.sh, depois de lib-comum.sh.
#
# Só aceita conexão TLS (hostssl), com o certificado curinga da instituição; o
# cliente valida o nome pelo FQDN da VM. A aplicação entra de APP_CIDR; o role de
# backup, somente leitura, só da VM de automação e de nenhuma outra origem.

POSTGRES_IMAGE="postgis/postgis:18-3.6"
POSTGRES_UID=999
POSTGRES_TLS_DIR="$DATA_BASE/postgres/tls"
POSTGRES_CONFIG_DIR="$DATA_BASE/postgres/config"

hba_postgres() {
    printf '%s\n' \
        'local all all trust' \
        "hostssl all ${ROLE_BACKUP} ${AUTOMACAO_IP}/32 scram-sha-256" \
        "host all ${ROLE_BACKUP} all reject" \
        "hostssl all all ${APP_CIDR} scram-sha-256"
}

unidade_postgres() {
    cat <<UNIT
[Unit]
Description=Uni+ PostgreSQL 18 + PostGIS (producao)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=300
LoadCredential=postgres-password:/etc/credstore/uniplus-postgres-password
ExecStartPre=-/usr/bin/docker rm -f uniplus-postgres
ExecStart=/usr/bin/docker run --rm --name uniplus-postgres \\
  --network host \\
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password \\
  -e POSTGRES_INITDB_ARGS=--encoding=UTF8 \\
  -v \${CREDENTIALS_DIRECTORY}/postgres-password:/run/secrets/postgres-password:ro \\
  -v ${DATA_BASE}/postgres/data:/var/lib/postgresql \\
  -v ${POSTGRES_TLS_DIR}:/etc/postgres-tls:ro \\
  -v ${POSTGRES_CONFIG_DIR}:/etc/postgres-config:ro \\
  ${POSTGRES_IMAGE} \\
  -c listen_addresses=0.0.0.0 \\
  -c max_connections=200 \\
  -c shared_buffers=512MB \\
  -c ssl=on \\
  -c ssl_cert_file=/etc/postgres-tls/public.crt \\
  -c ssl_key_file=/etc/postgres-tls/private.key \\
  -c ssl_min_protocol_version=TLSv1.2 \\
  -c hba_file=/etc/postgres-config/pg_hba.conf
ExecStop=/usr/bin/docker stop -t 30 uniplus-postgres

[Install]
WantedBy=multi-user.target
UNIT
}

step_postgres() {
    log_info "Configurando PostgreSQL com TLS obrigatório..."
    local creds_file="$DATA_BASE/postgres/.bootstrap-creds"

    run "sudo install -d -m 700 /etc/credstore"
    run "sudo mkdir -p $DATA_BASE/postgres/data"
    run "sudo chown 70:70 $DATA_BASE/postgres/data"
    run "sudo install -d -m 755 $POSTGRES_CONFIG_DIR"
    hba_postgres | gravar_arquivo_root "$POSTGRES_CONFIG_DIR/pg_hba.conf" 644
    instalar_par_tls "$POSTGRES_TLS_DIR" "$POSTGRES_UID"

    if ! $DRY_RUN && ! sudo test -f "$creds_file" \
        && sudo find "$DATA_BASE/postgres/data" -name PG_VERSION -print -quit 2>/dev/null | grep -q .; then
        log_error "$creds_file ausente, mas o cluster já existe; restaure a senha a partir do Vault."
        exit 1
    fi
    garantir_credencial "$creds_file" super_pw

    if $DRY_RUN; then
        echo "[DRY-RUN] copiaria super_pw para /etc/credstore/uniplus-postgres-password (modo 400)"
    else
        ler_credencial "$creds_file" super_pw | tr -d '\n' \
            | gravar_arquivo_root /etc/credstore/uniplus-postgres-password 400
    fi
    unidade_postgres | gravar_arquivo_root /etc/systemd/system/uniplus-postgres.service 644

    run "sudo systemctl daemon-reload"
    run "sudo systemctl enable uniplus-postgres"
    if $DRY_RUN; then
        echo "[DRY-RUN] systemctl start uniplus-postgres e esperaria o pg_isready"
    elif sudo systemctl is-active --quiet uniplus-postgres; then
        # O pg_hba vale com reload, sem derrubar conexões; o restante, no próximo restart.
        sudo docker exec uniplus-postgres psql -U postgres -tAc 'SELECT pg_reload_conf()' >/dev/null
        log_success "uniplus-postgres já ativo; pg_hba recarregado, o restante vale no próximo restart."
    else
        sudo systemctl start uniplus-postgres
        aguardar_postgres
    fi
}

aguardar_postgres() {
    local _
    for _ in $(seq 1 60); do
        if sudo docker exec uniplus-postgres pg_isready -h 127.0.0.1 -q 2>/dev/null; then
            log_success "PostgreSQL aceita conexões."
            return 0
        fi
        sleep 5
    done
    log_error "PostgreSQL não respondeu em 5 minutos."
    exit 1
}
