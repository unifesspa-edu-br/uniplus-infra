#!/usr/bin/env bash
# scripts/lab-standalone-single/setup-redis.sh
#
# Configura Redis 8.6.3 como container Docker gerenciado por systemd num host
# combinado de laboratório (K3s + data services na mesma VM), replicando o
# padrão do data-host real (scripts/bootstrap-standalone.sh, step_data_setup_redis)
# — mesma geração de ACL/credenciais, mesmo layout de systemd unit. A única
# diferença estrutural é DATA_HOST_IP: aqui é o IP da própria VM (host único),
# não de um data-host externo dedicado.
#
# Uso:
#   ./setup-redis.sh [--dry-run]
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

# Auto-detecta o IPv4 privado (RFC 1918) do host, mesmo filtro usado em
# bootstrap-standalone.sh — evita bindar Redis na interface errada quando
# `hostname -I` lista múltiplos endereços.
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
CREDS_FILE="$DATA_BASE/redis/.bootstrap-creds"
CONF_DIR="/etc/uniplus-redis"
REDIS_CONF="$CONF_DIR/redis.conf"
ACL_FILE="$CONF_DIR/users.acl"
UNIT_FILE="/etc/systemd/system/uniplus-redis.service"

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

# Diretórios: data dir 999:1000 mode 750 (uid do redis:8-alpine/8.6.3-alpine);
# conf dir 755 root:root (precisa ser traversável pelo uid 999 pós-drop de
# privilégios no entrypoint — mode 700 quebraria o startup).
run "sudo mkdir -p $DATA_BASE/redis/data $CONF_DIR"
run "sudo chown 999:1000 $DATA_BASE/redis/data"
run "sudo chmod 750 $DATA_BASE/redis/data"
run "sudo chown root:root $CONF_DIR"
run "sudo chmod 755 $CONF_DIR"

already_initialized=false
if ! $DRY_RUN && sudo test -f "$ACL_FILE" 2>/dev/null; then
    already_initialized=true
fi

# ---- Decisão 1: .bootstrap-creds (preservar / gerar / abortar) ----
if $DRY_RUN; then
    log_warn "Dry-run: senha Redis seria gerada/preservada em $CREDS_FILE"
elif sudo test -f "$CREDS_FILE" 2>/dev/null; then
    log_success "Bootstrap creds Redis já existentes — preservando senha."
elif $already_initialized; then
    log_error "$CREDS_FILE ausente, mas $ACL_FILE já existe."
    log_error "Regenerar senha agora produziria mismatch entre ACL file e credencial custodiada."
    exit 1
else
    log_info "Gerando senha Redis (256 bits)..."
    default_pw=$(openssl rand -hex 32)
    sudo tee "$CREDS_FILE" >/dev/null <<EOF
default_pw=$default_pw
EOF
    sudo chown root:root "$CREDS_FILE"
    sudo chmod 600 "$CREDS_FILE"
    log_warn "Senha gerada em $CREDS_FILE. Custódia obrigatória antes de descartar."
fi

# ---- Decisão 2: ACL file (sempre regerado a partir da senha custodiada) ----
if $DRY_RUN; then
    log_warn "Dry-run: ACL file seria escrito em $ACL_FILE"
elif sudo test -f "$CREDS_FILE" 2>/dev/null; then
    pw=$(sudo grep '^default_pw=' "$CREDS_FILE" | cut -d= -f2)
    if [[ -z "$pw" ]]; then
        log_error "default_pw vazio em $CREDS_FILE — não posso (re)gerar ACL file."
        exit 1
    fi
    sudo tee "$ACL_FILE" >/dev/null <<EOF
user default on >$pw ~* &* +@all
EOF
    sudo chown 999:1000 "$ACL_FILE"
    sudo chmod 600 "$ACL_FILE"
    unset pw
fi

# redis.conf: bind explícito (protected-mode exige bind+auth), persistência
# híbrida AOF+RDB, memory cap conservador para VM de lab.
if $DRY_RUN; then
    log_warn "Dry-run: redis.conf seria escrito em $REDIS_CONF"
else
    sudo tee "$REDIS_CONF" >/dev/null <<CONF
bind $DATA_HOST_IP 127.0.0.1 -::1
port 6379
protected-mode yes

aclfile /usr/local/etc/redis/users.acl

appendonly yes
appendfsync everysec
appendfilename "appendonly.aof"
save 3600 1 300 100 60 10000

maxmemory 1gb
maxmemory-policy allkeys-lru

dir /data

logfile ""
loglevel notice
CONF
    sudo chown root:root "$REDIS_CONF"
    sudo chmod 644 "$REDIS_CONF"
fi

# systemd unit: sempre re-aplicado (cheap, corrige drift).
if $DRY_RUN; then
    log_warn "Dry-run: unit systemd seria escrito em $UNIT_FILE"
else
    sudo tee "$UNIT_FILE" >/dev/null <<UNIT
[Unit]
Description=Uni+ Redis 8.6.3 (lab standalone-single)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=120

ExecStartPre=-/usr/bin/docker rm -f uniplus-redis
ExecStart=/usr/bin/docker run --rm --name uniplus-redis \\
  --network host \\
  -v $DATA_BASE/redis/data:/data \\
  -v /etc/uniplus-redis:/usr/local/etc/redis:ro \\
  redis:8.6.3-alpine \\
  redis-server /usr/local/etc/redis/redis.conf

ExecStop=/usr/bin/docker stop -t 30 uniplus-redis

[Install]
WantedBy=multi-user.target
UNIT
fi

run "sudo systemctl daemon-reload"
run "sudo systemctl enable uniplus-redis"

if $DRY_RUN; then
    log_warn "Dry-run: systemctl start uniplus-redis + smoke test PING/PONG"
elif sudo systemctl is-active --quiet uniplus-redis; then
    log_success "uniplus-redis já ativo — preservando state (sem restart)."
else
    sudo systemctl start uniplus-redis
    log_info "Aguardando Redis aceitar conexões..."
    pw=$(sudo grep '^default_pw=' "$CREDS_FILE" | cut -d= -f2)
    if [[ -z "$pw" ]]; then
        log_error "default_pw vazio em $CREDS_FILE — não consigo validar PING."
        exit 1
    fi
    attempts=0
    until sudo docker exec -i uniplus-redis sh -c \
            'read -r PW; REDISCLI_AUTH="$PW" redis-cli ping' \
            <<<"$pw" 2>/dev/null | grep -q PONG; do
        attempts=$(( attempts + 1 ))
        if (( attempts >= 12 )); then
            log_error "Redis não respondeu PONG em 60s. Ver: sudo journalctl -u uniplus-redis -n 50"
            exit 1
        fi
        sleep 5
    done
    log_success "uniplus-redis ativo + PING/PONG OK."
    unset pw
fi
