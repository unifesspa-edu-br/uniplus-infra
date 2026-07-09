#!/usr/bin/env bash
# scripts/lab-standalone-single/setup-minio.sh
#
# Configura MinIO como container Docker gerenciado por systemd num host
# combinado de laboratório (K3s + data services na mesma VM), replicando o
# padrão do data-host real (scripts/bootstrap-standalone.sh,
# step_data_setup_minio + step_data_bootstrap_minio_buckets) — já é
# single-node single-drive (SNSD), sem adaptação de topologia necessária.
# Sem erasure coding (precisa ≥4 drives) — zero proteção contra corrupção do
# drive; backup externo é responsabilidade do operador (mesmo trade-off do
# script real).
#
# Uso:
#   ./setup-minio.sh [--dry-run] [--skip-buckets]
#
# Variáveis de ambiente:
#   DATA_HOST_IP   IPv4 privado a bindar (default: auto-detectado via `hostname -I`)
#   DATA_BASE      Diretório base dos volumes de dados (default: /var/lib/uniplus)
#
# Pré-requisitos: Docker instalado, usuário com sudo sem senha (ou rodar via sudo).
set -euo pipefail

DRY_RUN=false
SKIP_BUCKETS=false
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        --skip-buckets) SKIP_BUCKETS=true ;;
        -h|--help)
            echo "Uso: $0 [--dry-run] [--skip-buckets]"
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
CREDS_FILE="$DATA_BASE/minio/.bootstrap-creds"
ENV_FILE="/etc/uniplus-minio.env"
UNIT_FILE="/etc/systemd/system/uniplus-minio.service"
MINIO_IMAGE="quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z"
MC_IMAGE="quay.io/minio/mc:latest"

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

# Data dir 1000:1000 (uid/gid do usuário dinâmico criado pelo entrypoint da
# imagem — MINIO_UID/MINIO_GID abaixo). Pré-chown evita "Permission denied"
# na primeira escrita de .minio.sys/.
run "sudo mkdir -p $DATA_BASE/minio/data"
run "sudo chown 1000:1000 $DATA_BASE/minio/data"
run "sudo chmod 750 $DATA_BASE/minio/data"

already_initialized=false
if ! $DRY_RUN && sudo test -d "$DATA_BASE/minio/data/.minio.sys" 2>/dev/null; then
    already_initialized=true
fi

# ---- Decisão: .bootstrap-creds (preservar / gerar / abortar) ----
# root_user/root_pw NUNCA admin/minioadmin — gerados via openssl rand.
if $DRY_RUN; then
    log_warn "Dry-run: credenciais MinIO seriam geradas/preservadas em $CREDS_FILE"
elif sudo test -f "$CREDS_FILE" 2>/dev/null; then
    log_success "Bootstrap creds MinIO já existentes — preservando credenciais."
elif $already_initialized; then
    log_error "$CREDS_FILE ausente, mas MinIO já foi formatado em $DATA_BASE/minio/data."
    log_error "Regenerar credenciais agora produziria mismatch com o storage já formatado."
    exit 1
else
    log_info "Gerando credenciais MinIO..."
    root_user=$(openssl rand -hex 16)
    root_pw=$(openssl rand -hex 32)
    sudo tee "$CREDS_FILE" >/dev/null <<EOF
root_user=$root_user
root_pw=$root_pw
EOF
    sudo chown root:root "$CREDS_FILE"
    sudo chmod 600 "$CREDS_FILE"
    log_warn "Credenciais geradas em $CREDS_FILE. Custódia obrigatória antes de descartar."
fi

# EnvironmentFile: nunca passar credenciais inline no ExecStart (evita
# exposição via /proc/<pid>/cmdline). Docker recebe via `-e VAR` (bare),
# systemd resolve o valor do EnvironmentFile no processo docker (client),
# não no daemon.
if $DRY_RUN; then
    log_warn "Dry-run: EnvironmentFile seria escrito em $ENV_FILE"
elif sudo test -f "$CREDS_FILE" 2>/dev/null; then
    root_user=$(sudo grep '^root_user=' "$CREDS_FILE" | cut -d= -f2)
    root_pw=$(sudo grep '^root_pw=' "$CREDS_FILE" | cut -d= -f2)
    if [[ -z "$root_user" || -z "$root_pw" ]]; then
        log_error "root_user/root_pw vazios em $CREDS_FILE — não posso (re)gerar $ENV_FILE."
        exit 1
    fi
    sudo tee "$ENV_FILE" >/dev/null <<EOF
MINIO_ROOT_USER=$root_user
MINIO_ROOT_PASSWORD=$root_pw
MINIO_USERNAME=minio
MINIO_GROUPNAME=minio
MINIO_UID=1000
MINIO_GID=1000
EOF
    sudo chown root:root "$ENV_FILE"
    sudo chmod 600 "$ENV_FILE"
    unset root_user root_pw
fi

# systemd unit: sempre re-aplicado (cheap, corrige drift). Console (9001)
# não é exposto externamente — sem IngressRoute/publicação; acesso só via
# kubectl port-forward ou SSH tunnel.
if $DRY_RUN; then
    log_warn "Dry-run: unit systemd seria escrito em $UNIT_FILE"
else
    sudo tee "$UNIT_FILE" >/dev/null <<UNIT
[Unit]
Description=Uni+ MinIO (lab standalone-single, SNSD)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=120
EnvironmentFile=$ENV_FILE

ExecStartPre=-/usr/bin/docker rm -f uniplus-minio
ExecStart=/usr/bin/docker run --rm --name uniplus-minio \\
  --network host \\
  -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \\
  -e MINIO_USERNAME -e MINIO_GROUPNAME -e MINIO_UID -e MINIO_GID \\
  -v $DATA_BASE/minio/data:/data \\
  $MINIO_IMAGE \\
  server --address $DATA_HOST_IP:9000 --console-address $DATA_HOST_IP:9001 /data

ExecStop=/usr/bin/docker stop -t 30 uniplus-minio

[Install]
WantedBy=multi-user.target
UNIT
fi

run "sudo systemctl daemon-reload"
run "sudo systemctl enable uniplus-minio"

if $DRY_RUN; then
    log_warn "Dry-run: systemctl start uniplus-minio + smoke test /minio/health/live"
elif sudo systemctl is-active --quiet uniplus-minio; then
    log_success "uniplus-minio já ativo — preservando state (sem restart)."
else
    sudo systemctl start uniplus-minio
    log_info "Aguardando MinIO aceitar conexões..."
    attempts=0
    until curl -sf "http://$DATA_HOST_IP:9000/minio/health/live" >/dev/null 2>&1; do
        attempts=$(( attempts + 1 ))
        if (( attempts >= 18 )); then
            log_error "MinIO não respondeu em 90s. Ver: sudo journalctl -u uniplus-minio -n 50"
            exit 1
        fi
        sleep 5
    done
    log_success "uniplus-minio ativo + /minio/health/live OK."
fi

# ---- Buckets baseline (idempotente) ----
if $SKIP_BUCKETS; then
    log_warn "Pulando criação de buckets (--skip-buckets)."
elif $DRY_RUN; then
    log_warn "Dry-run: buckets baseline seriam criados via mc mb --ignore-existing"
else
    root_user=$(sudo grep '^root_user=' "$CREDS_FILE" | cut -d= -f2)
    root_pw=$(sudo grep '^root_pw=' "$CREDS_FILE" | cut -d= -f2)
    log_info "Criando buckets baseline..."
    # Credenciais nunca em argv (visível via `ps`/`/proc/<pid>/cmdline` para
    # qualquer usuário do host) — passadas via --env-file num arquivo
    # temporário root:root 0600, removido logo após o uso.
    mc_env_file=$(sudo mktemp /tmp/uniplus-mc-env.XXXXXX)
    sudo bash -c "cat > '$mc_env_file'" <<EOF
MC_HOST_uniplus=http://${root_user}:${root_pw}@${DATA_HOST_IP}:9000
EOF
    sudo chown root:root "$mc_env_file"
    sudo chmod 600 "$mc_env_file"
    sudo docker run --rm --network host \
        --env-file "$mc_env_file" \
        "$MC_IMAGE" \
        mb --ignore-existing \
        uniplus/keycloak-backups \
        uniplus/loki-chunks \
        uniplus/tempo-traces \
        uniplus/app-uploads \
        uniplus/uniplus-storage
    sudo shred -u "$mc_env_file" 2>/dev/null || sudo rm -f "$mc_env_file"
    unset root_user root_pw
    log_success "Buckets baseline prontos (keycloak-backups, loki-chunks, tempo-traces, app-uploads, uniplus-storage)."
fi
