#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — lab-standalone-single
#
# Consolida as Features #398 (Redis/MinIO/Kafka) e #399 (Vault + External
# Secrets Operator) num único script idempotente para o host combinado de
# laboratório (K3s + Docker na mesma VM), replicando o padrão
# `--role=<role>` de scripts/bootstrap-standalone.sh — mas sem roles: aqui
# é um único host que acumula os dois papéis (k8s-host + data-host) do
# standalone-compact real.
#
# Uso:
#   ./bootstrap.sh [--dry-run] [--skip-platform]
#
# Opções:
#   --dry-run         Mostra o que seria feito, sem aplicar nada.
#   --skip-platform   Para depois dos componentes de dados (Docker, K3s,
#                     Postgres, Redis, MinIO, Kafka) — não instala
#                     Vault/ESO nem popula secrets. Útil para validar a
#                     camada de dados isoladamente.
#
# Pré-requisitos: Ubuntu 22.04+/24.04 LTS, usuário com sudo sem senha, não
# rodar como root.
#
# Escopo desta Task (#415 — Feature #401): consolida Docker→K3s→Postgres→
# Redis→MinIO→Kafka→Vault→ESO. NÃO cobre o deploy das APIs de negócio
# (uniplus-api-host/uniplus-api-portal) — cada uma depende de artefatos
# externos a este repositório (build de imagem a partir do uniplus-api,
# role+db Postgres dedicados, LocalKey de cifragem) documentados nos READMEs
# de environments/lab-standalone-single/ e apps/uniplus-api-{host,portal}/,
# fora do fluxo "do zero numa VM nova" que este script garante.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# O instalador oficial do K3s cria /usr/local/bin/{kubectl,ctr,crictl} como
# symlinks para o binário k3s unificado (detecta o subcomando via argv[0]).
# Nesse modo, "kubectl" usa /etc/rancher/k3s/k3s.yaml (root:root 600) como
# kubeconfig default nativo — IGNORA ~/.kube/config mesmo quando ele existe
# e está correto, a menos que KUBECONFIG seja exportado explicitamente.
# Sem isto, todo kubectl/helm deste script falha com "permission denied"
# assim que o K3s já estiver instalado (mesmo com o kubeconfig do usuário
# copiado corretamente por step_install_k3s).
export KUBECONFIG="$HOME/.kube/config"

# ============== Versões pinadas ==============
# Atualizado em 2026-07-12: v1.31.4+k3s1 estava EOL desde nov/2025 (achado
# durante o spike de PathPrefix, ver docs/validacao/spike-pathprefix-hml-
# 2026-07-12.md). K3s 1.36.2+k3s1 é a mais recente estável (release
# 2026-05-27) — bootstrap é sempre from-scratch (sem upgrade de cluster
# vivo), então o salto de minor version não tem caminho de migração a
# validar. Helm fica na última minor da série 3.x (3.21.2, jun/2026) —
# Helm 4 já é a série estável atual, mas é major version nova, sem
# validação de compatibilidade com os charts deste repo; não trocar sem
# avaliação própria. Reconfirmar ambas em https://docs.k3s.io/release-notes
# e https://github.com/helm/helm/releases antes do próximo bootstrap —
# release cadence de ambos é rápida.
K3S_VERSION="v1.36.2+k3s1"
HELM_VERSION="v3.21.2"

# ============== Defaults ==============
DRY_RUN=false
SKIP_PLATFORM=false

DATA_BASE="/var/lib/uniplus"
VAULT_NAMESPACE="vault"
VAULT_POD="vault-0"
ESO_NAMESPACE="external-secrets"
ENV_VALUES="$REPO_ROOT/environments/lab-standalone-single/values.yaml"

# ============== Logging ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        bash -c "$*"
    fi
}

# ============== Arquitetura ==============
case "$(uname -m)" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *)       log_error "Arquitetura não suportada: $(uname -m). Esperado x86_64 ou aarch64."; exit 1 ;;
esac

usage() {
    cat <<EOF
Uso: $0 [--dry-run] [--skip-platform]

Consolida Docker→K3s→Postgres→Redis→MinIO→Kafka→Vault→ESO no host
combinado do lab (host único, sem roles). Ver cabeçalho do script para
o que fica fora de escopo (APIs de negócio).

Opções:
  --dry-run          Mostra o que seria feito, sem aplicar.
  --skip-platform     Para depois dos componentes de dados (não instala
                      Vault/ESO nem popula secrets).
  -h, --help          Esta mensagem.

Exemplos:
  $0 --dry-run
  $0
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)         DRY_RUN=true ;;
        --skip-platform)   SKIP_PLATFORM=true ;;
        -h|--help)         usage; exit 0 ;;
        *) log_error "Opção inválida: $arg"; usage; exit 2 ;;
    esac
done

if [[ "$EUID" -eq 0 ]]; then
    log_error "Não rode como root — o script usa sudo internamente."
    exit 1
fi

if ! sudo -n true 2>/dev/null; then
    log_error "sudo sem senha é obrigatório para este usuário (ver docs/RUNBOOKS.md)."
    exit 1
fi

# ============================================================================
# Steps — Docker + K3s + Helm
# ============================================================================

step_install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        log_success "Docker já instalado: $(docker --version)"
        return
    fi

    log_info "Instalando Docker + Compose v2..."
    run "sudo apt-get update -qq"
    run "sudo apt-get install -y docker.io docker-compose-v2"
    run "sudo systemctl enable --now docker"
    run "sudo usermod -aG docker $USER"
    log_warn "Logout/login necessário para aplicar o grupo 'docker' (se ainda não estiver nele)."
    log_success "Docker instalado."
}

step_install_k3s() {
    if command -v k3s &>/dev/null; then
        log_success "K3s já instalado: $(k3s --version | head -1)"
    else
        local node_ip
        node_ip=$(hostname -I | awk '{print $1}')

        log_info "Instalando K3s $K3S_VERSION (host combinado, IP: $node_ip)..."

        # --disable traefik: o chart platform/traefik/ (fora de escopo do lab
        # por ora) instalaria o IngressController do projeto; sem --disable
        # o Traefik bundled do K3s competiria pelo bind 80/443.
        # --disable servicelb: sem LoadBalancer externo no lab.
        # --write-kubeconfig-mode 644: kubeconfig legível sem sudo — mesmo
        # padrão de scripts/bootstrap-standalone.sh. (A instalação manual
        # original desta VM de lab não usou essa flag — ver nota no README.)
        run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
            --node-name uniplus-lab \
            --tls-san $node_ip \
            --disable servicelb \
            --disable traefik \
            --write-kubeconfig-mode 644"
    fi

    run "mkdir -p $HOME/.kube"
    run "sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config"
    run "sudo chown $(id -u):$(id -g) $HOME/.kube/config"
    log_success "K3s pronto."
}

step_install_helm() {
    if command -v helm &>/dev/null; then
        log_success "Helm já instalado: $(helm version --short)"
        return
    fi

    log_info "Instalando Helm $HELM_VERSION (linux-$ARCH)..."
    local helm_tar="/tmp/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
    local helm_sha="/tmp/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz.sha256sum"
    run "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz -o $helm_tar"
    run "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz.sha256sum -o $helm_sha"
    run "echo \"\$(awk '{print \$1}' $helm_sha)  $helm_tar\" | sha256sum -c"
    run "tar -xzf $helm_tar -C /tmp linux-${ARCH}/helm"
    run "sudo install /tmp/linux-${ARCH}/helm /usr/local/bin/helm"
    run "rm -rf $helm_tar $helm_sha /tmp/linux-${ARCH}"
    log_success "Helm $HELM_VERSION instalado."
}

# ============================================================================
# Step — Postgres (mesmo padrão systemd/LoadCredential do data-host real,
# imagem postgis/postgis em vez de postgres:18-alpine — módulo Geo exige
# PostGIS). Sem init SQL genérico: cada app (Keycloak, Geo, Host, Portal)
# cria seu próprio role+db via procedimento documentado no README do
# respectivo chart/environment, fora deste script. Diferente do
# bootstrap-standalone.sh real: NÃO montamos nada sobre
# /docker-entrypoint-initdb.d aqui — a imagem postgis/postgis já embute ali
# o script que cria template_postgis + carrega as extensions; um bind mount
# de diretório vazio (como o real faz sobre postgres:18-alpine, que não tem
# init script próprio) esconderia esse script da imagem e subiria o cluster
# sem PostGIS, justamente o motivo de usar essa imagem em vez da vanilla.
# ============================================================================

step_setup_postgres() {
    log_info "Configurando Postgres 18 + PostGIS 3.6 systemd..."

    local creds_file="$DATA_BASE/postgres/.bootstrap-creds"
    local cred_dir="/etc/credstore"
    local cred_file="$cred_dir/uniplus-postgres-password"
    local unit_file="/etc/systemd/system/uniplus-postgres.service"

    run "sudo mkdir -p $DATA_BASE/postgres/data"
    run "sudo chown 70:70 $DATA_BASE/postgres/data"

    # Detectar se o cluster já foi inicializado pelo entrypoint (mesmo guard
    # do bootstrap-standalone.sh §9.1/RUNBOOKS §9.2) — PG_VERSION é escrito
    # por initdb na primeira inicialização, robusto a variações de layout.
    local cluster_initialized=false
    if ! $DRY_RUN && \
       sudo find "$DATA_BASE/postgres/data" -name PG_VERSION -print -quit 2>/dev/null | grep -q .; then
        cluster_initialized=true
    fi

    if sudo test -f "$creds_file" 2>/dev/null; then
        log_success "Bootstrap creds do Postgres já existentes — preservando senha."
    elif $DRY_RUN; then
        log_warn "Dry-run: senha inicial seria gerada em $creds_file"
    elif $cluster_initialized; then
        # Guard: cluster já inicializado mas sem .bootstrap-creds (operador
        # removeu após custódia). Regenerar agora produziria mismatch entre
        # o novo super_pw e a senha já persistida no cluster.
        log_error "$creds_file ausente, mas cluster Postgres já existe em $DATA_BASE/postgres/data"
        log_error "Regenerar a senha agora produziria mismatch com o cluster já formatado."
        log_error "Restaure $creds_file a partir do Vault — ver docs/RUNBOOKS.md §9.4."
        exit 1
    else
        log_info "Gerando senha do superusuário (256 bits)..."
        local super_pw
        super_pw=$(openssl rand -hex 32)
        sudo tee "$creds_file" >/dev/null <<EOF
super_pw=$super_pw
EOF
        sudo chown root:root "$creds_file"
        sudo chmod 600 "$creds_file"
        log_warn "Senha gerada em $creds_file. Custódia obrigatória — ver docs/RUNBOOKS.md §9.2."
        unset super_pw
    fi

    if $DRY_RUN; then
        echo "[DRY-RUN] Criaria $cred_dir + escreveria $cred_file (super_pw lido de $creds_file)"
    else
        local super_pw_current
        super_pw_current=$(sudo grep '^super_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$super_pw_current" ]]; then
            log_error "Não consegui ler super_pw de $creds_file. Abortando."
            exit 1
        fi
        sudo mkdir -p "$cred_dir"
        sudo chown root:root "$cred_dir"
        sudo chmod 700 "$cred_dir"
        printf '%s' "$super_pw_current" | sudo tee "$cred_file" >/dev/null
        sudo chown root:root "$cred_file"
        sudo chmod 400 "$cred_file"
        unset super_pw_current
    fi

    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $unit_file"
    else
        sudo tee "$unit_file" >/dev/null <<'UNIT'
[Unit]
Description=Uni+ Postgres 18 + PostGIS 3.6 (lab standalone)
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=120

LoadCredential=postgres-password:/etc/credstore/uniplus-postgres-password

ExecStartPre=-/usr/bin/docker rm -f uniplus-postgres
ExecStart=/usr/bin/docker run --rm --name uniplus-postgres \
  --network host \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password \
  -e POSTGRES_INITDB_ARGS=--encoding=UTF8 \
  -v ${CREDENTIALS_DIRECTORY}/postgres-password:/run/secrets/postgres-password:ro \
  -v /var/lib/uniplus/postgres/data:/var/lib/postgresql \
  postgis/postgis:18-3.6 \
  -c listen_addresses=0.0.0.0 \
  -c max_connections=200 \
  -c shared_buffers=512MB

ExecStop=/usr/bin/docker stop -t 30 uniplus-postgres

[Install]
WantedBy=multi-user.target
UNIT
    fi

    run "sudo systemctl daemon-reload"
    run "sudo systemctl enable uniplus-postgres"

    if $DRY_RUN; then
        echo "[DRY-RUN] systemctl start uniplus-postgres + aguardaria pg_isready (60s)"
    elif sudo systemctl is-active --quiet uniplus-postgres; then
        log_success "uniplus-postgres já ativo — preservando state (sem restart)."
    else
        sudo systemctl start uniplus-postgres
        log_info "Aguardando Postgres aceitar conexões..."
        local attempts=0
        until sudo docker exec uniplus-postgres pg_isready -U postgres &>/dev/null; do
            attempts=$(( attempts + 1 ))
            if (( attempts >= 12 )); then
                log_error "Postgres não ficou ready em 60s. Ver: sudo journalctl -u uniplus-postgres -n 50"
                exit 1
            fi
            sleep 5
        done
        log_success "uniplus-postgres ativo + pg_isready OK."
    fi
}

# ============================================================================
# Steps — Redis, MinIO, Kafka: delegam para os scripts já formalizados
# (Tasks #406/#407/#408), evitando duplicar a lógica de idempotência de
# cada um aqui.
# ============================================================================

step_setup_redis() {
    log_info "Configurando Redis (delegando para setup-redis.sh)..."
    if $DRY_RUN; then
        "$SCRIPT_DIR/setup-redis.sh" --dry-run
    else
        "$SCRIPT_DIR/setup-redis.sh"
    fi
}

step_setup_minio() {
    log_info "Configurando MinIO (delegando para setup-minio.sh)..."
    if $DRY_RUN; then
        "$SCRIPT_DIR/setup-minio.sh" --dry-run
    else
        "$SCRIPT_DIR/setup-minio.sh"
    fi
}

step_setup_kafka() {
    log_info "Configurando Kafka (delegando para setup-kafka.sh)..."
    if $DRY_RUN; then
        "$SCRIPT_DIR/setup-kafka.sh" --dry-run
    else
        "$SCRIPT_DIR/setup-kafka.sh"
    fi
}

# ============================================================================
# Steps — Vault + External Secrets Operator (Feature #399, Tasks #409/#410)
# ============================================================================

step_deploy_vault() {
    log_info "Deploy do Vault (platform/vault/)..."

    if $DRY_RUN; then
        echo "[DRY-RUN] helm dependency update platform/vault/"
        echo "[DRY-RUN] kubectl create namespace vault (idempotente)"
        echo "[DRY-RUN] helm install/upgrade vault platform/vault/ -f $ENV_VALUES --namespace vault"
        return
    fi

    # `networkPolicy.kubeApiCidrs` em $ENV_VALUES é uma lista estática (não
    # gerada por este script — mesmo padrão de todo values.yaml de
    # environment neste repo, atado à infra real que descreve). Se a VM
    # rodando este bootstrap não é a mesma cujo IP está commitado ali, o
    # egress do Vault/ESO ao Service kubernetes fica bloqueado pelo
    # kube-router (mesmo bug da Task #410) — falhar cedo aqui em vez de
    # deployar Vault/ESO com NetworkPolicy silenciosamente quebrada.
    local host_ip
    host_ip=$(hostname -I 2>/dev/null | tr ' ' '\n' \
        | grep -E '^(10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' \
        | head -1)
    if [[ -n "$host_ip" ]] && ! grep -A5 '^  kubeApiCidrs:' "$ENV_VALUES" | grep -q "$host_ip/32"; then
        log_error "IP deste host ($host_ip) não está em networkPolicy.kubeApiCidrs de $ENV_VALUES."
        log_error "Atualize o values.yaml do environment com o IP real desta VM antes de continuar."
        exit 1
    fi

    helm dependency update "$REPO_ROOT/platform/vault/" >/dev/null
    kubectl create namespace "$VAULT_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    if helm status vault -n "$VAULT_NAMESPACE" &>/dev/null; then
        # --force: o Vault Agent Injector gerencia dinamicamente o caBundle
        # do MutatingWebhookConfiguration, causando disputa de field-ownership
        # no apply do Helm em upgrades subsequentes (documentado no upstream
        # hashicorp/vault-helm). Versão do Helm pinada (v3.16.4) não suporta
        # --server-side; --force é a flag equivalente disponível nela.
        helm upgrade vault "$REPO_ROOT/platform/vault/" -f "$ENV_VALUES" --namespace "$VAULT_NAMESPACE" --force
        log_success "Release 'vault' atualizado."
    else
        helm install vault "$REPO_ROOT/platform/vault/" -f "$ENV_VALUES" --namespace "$VAULT_NAMESPACE"
        log_success "Release 'vault' instalado."
    fi

    log_info "Aguardando pod $VAULT_POD ficar Ready..."
    kubectl wait --for=condition=Ready "pod/$VAULT_POD" -n "$VAULT_NAMESPACE" --timeout=180s || true
}

step_init_unseal_vault() {
    local creds_file="$DATA_BASE/vault/.bootstrap-creds.json"

    if $DRY_RUN; then
        echo "[DRY-RUN] vault operator init -key-shares=1 -key-threshold=1 (se ainda não inicializado)"
        echo "[DRY-RUN] vault operator unseal (se sealed)"
        return
    fi

    # `vault status` sai com código 2 quando sealed/uninitialized (não é erro
    # — é o contrato documentado do comando). Com `set -o pipefail` ativo,
    # deixar esse exit code dentro do pipe faz `| python3 ...` "vencer" o
    # parse só quando bem-sucedido; quando o pipeline como um todo propaga o
    # 2 do `vault status`, o `|| echo` do fallback roda ADEMAIS da saída já
    # capturada do python3 — a variável vira duas linhas ("True\ntrue") e o
    # `[[ == "True" ]]` falha silenciosamente. Capturar o JSON separado do
    # parse evita a mistura.
    local status_json initialized
    status_json=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault status -format=json 2>/dev/null || true)
    initialized=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["initialized"])' 2>/dev/null || echo "false")

    if [[ "$initialized" != "True" ]]; then
        log_info "Inicializando Vault (Shamir 1 key-share/threshold — simplificação de lab)..."
        sudo mkdir -p "$DATA_BASE/vault"
        kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault operator init -key-shares=1 -key-threshold=1 -format=json \
            | sudo tee "$creds_file" >/dev/null
        sudo chown root:root "$creds_file"
        sudo chmod 600 "$creds_file"
        log_warn "Credenciais do Vault geradas em $creds_file. Custódia obrigatória — nunca commitar."
    else
        log_success "Vault já inicializado — preservando estado."
    fi

    local sealed
    status_json=$(kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault status -format=json 2>/dev/null || true)
    sealed=$(printf '%s' "$status_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sealed"])' 2>/dev/null || echo "true")

    if [[ "$sealed" == "True" ]]; then
        if ! sudo test -f "$creds_file" 2>/dev/null; then
            log_error "Vault sealed mas $creds_file ausente — não consigo desselar automaticamente."
            log_error "Restaure a unseal key custodiada e rode: kubectl exec -n vault $VAULT_POD -- vault operator unseal <key>"
            exit 1
        fi
        local unseal_key
        unseal_key=$(sudo python3 -c "import json; print(json.load(open('$creds_file'))['unseal_keys_b64'][0])")
        # BUG CORRIGIDO 2026-07-12 (achado no spike, ver docs/validacao/
        # spike-pathprefix-hml-2026-07-12.md): o Vault CLI NÃO lê a unseal
        # key via stdin com "-" como sentinel — "-" é tratado como valor
        # literal da key e falha com "must be a valid hex or base64
        # string" (confirmado empiricamente contra Vault 1.21.2). Passar
        # como argumento posicional é a única forma de automatizar sem TTY
        # interativo — expõe a key brevemente em `ps`/`/proc/<pid>/cmdline`
        # dentro do pod durante a única chamada, aceitável neste contexto
        # (bootstrap non-interativo, sem outro operador com acesso ao pod
        # nesse instante).
        kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- vault operator unseal "$unseal_key" >/dev/null
        unset unseal_key
        log_success "Vault desselado."
    else
        log_success "Vault já desselado."
    fi
}

step_configure_vault_auth() {
    local creds_file="$DATA_BASE/vault/.bootstrap-creds.json"

    if $DRY_RUN; then
        echo "[DRY-RUN] vault auth enable kubernetes + policy external-secrets-read + role external-secrets"
        return
    fi

    local root_token
    root_token=$(sudo python3 -c "import json; print(json.load(open('$creds_file'))['root_token'])")

    # Root token nunca em argv de kubectl/vault (visível via /proc/<pid>/cmdline
    # ou `ps` local enquanto o comando roda) — mesmo padrão de
    # seed-vault-secrets.sh: arquivo temporário 700/600, copiado pro pod,
    # consumido via `cat` dentro do heredoc remoto, nunca interpolado na
    # string de um `sh -c`. Subshell isola o trap de limpeza sem afetar os
    # steps seguintes do script.
    (
        tmpdir=$(mktemp -d)
        # Limpeza local sempre; a remota é best-effort e cobre o caso em que
        # o `kubectl exec` do heredoc nem chega a iniciar (ex.: timeout de
        # API, admission webhook) — nesse cenário o trap remoto (dentro do
        # heredoc) nunca roda, deixando o token em texto puro órfão no pod
        # até restart/limpeza manual. Mesmo padrão de seed-vault-secrets.sh.
        trap 'shred -u "$tmpdir"/* 2>/dev/null; rm -rf "$tmpdir"; kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- rm -rf /tmp/vault-auth-setup 2>/dev/null || true' EXIT
        chmod 700 "$tmpdir"
        printf '%s' "$root_token" > "$tmpdir/vault_token"
        chmod 600 "$tmpdir/vault_token"

        kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- mkdir -p /tmp/vault-auth-setup
        kubectl cp "$tmpdir/vault_token" "$VAULT_NAMESPACE/$VAULT_POD:/tmp/vault-auth-setup/vault_token"

        # `set -e` + trap remoto: sem isso, cada `vault ...` roda independente
        # do resultado do anterior e o `secrets enable || true` final faria o
        # heredoc sempre retornar 0, mascarando falha real de `auth
        # enable`/`policy write`/`write role` — o bootstrap seguiria para
        # ESO/seed com o Vault mal configurado e reportaria sucesso. `auth
        # enable` só roda se o mount kubernetes/ ainda não existir (reabilitar
        # um mount ativo é erro no Vault); config/policy/role SEMPRE rodam
        # (write é idempotente por natureza no Vault) — uma execução anterior
        # que habilitou o mount mas falhou antes de escrever a policy/role é
        # corrigida na próxima execução, em vez de ficar faltando pra sempre.
        kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- sh <<'REMOTE_SCRIPT'
set -e
trap 'rm -rf /tmp/vault-auth-setup' EXIT
export VAULT_TOKEN="$(cat /tmp/vault-auth-setup/vault_token)"

if ! vault auth list -format=json | grep -q '"kubernetes/"'; then
    vault auth enable kubernetes
fi
vault write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc.cluster.local
vault policy write external-secrets-read - <<'POLICY'
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read"] }
POLICY
vault write auth/kubernetes/role/external-secrets \
    bound_service_account_names=external-secrets \
    bound_service_account_namespaces=external-secrets \
    policies=external-secrets-read \
    ttl=1h
vault secrets enable -path=secret -version=2 kv || true
REMOTE_SCRIPT
    )
    unset root_token
    log_success "Auth Kubernetes + policy external-secrets-read + role external-secrets reconciliados."
}

step_deploy_eso() {
    log_info "Deploy do External Secrets Operator (platform/external-secrets/)..."

    if $DRY_RUN; then
        echo "[DRY-RUN] helm dependency update platform/external-secrets/"
        echo "[DRY-RUN] kubectl create namespace external-secrets (idempotente)"
        echo "[DRY-RUN] helm install (sem CSS) + helm upgrade (com CSS) -f $ENV_VALUES"
        return
    fi

    helm dependency update "$REPO_ROOT/platform/external-secrets/" >/dev/null
    kubectl create namespace "$ESO_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    if helm status external-secrets -n "$ESO_NAMESPACE" &>/dev/null; then
        helm upgrade external-secrets "$REPO_ROOT/platform/external-secrets/" -f "$ENV_VALUES" --namespace "$ESO_NAMESPACE"
        log_success "Release 'external-secrets' atualizado."
    else
        # CRDs do subchart upstream vêm como templates normais (não a pasta
        # crds/ especial do Helm) — não podem coexistir com o
        # ClusterSecretStore no mesmo helm install (client resolve o kind
        # antes de aplicar qualquer objeto). -f já entra na primeira
        # instalação: sem isso, a NetworkPolicy nasce com os defaults do
        # chart (sem o CIDR do host) e o controller crashloopa.
        helm install external-secrets "$REPO_ROOT/platform/external-secrets/" -f "$ENV_VALUES" --namespace "$ESO_NAMESPACE" --set clusterSecretStore.enabled=false
        log_info "Aguardando pods do ESO ficarem Ready..."
        kubectl wait --for=condition=Ready pod --all -n "$ESO_NAMESPACE" --timeout=120s || true
        helm upgrade external-secrets "$REPO_ROOT/platform/external-secrets/" -f "$ENV_VALUES" --namespace "$ESO_NAMESPACE"
        log_success "Release 'external-secrets' instalado (2 etapas) com ClusterSecretStore habilitado."
    fi
}

step_seed_secrets() {
    log_info "Populando secrets iniciais no Vault (delegando para seed-vault-secrets.sh)..."

    # seed-vault-secrets.sh faz require_file nos .bootstrap-creds de
    # redis/minio/kafka/vault ANTES do resumo --dry-run — numa VM nova, onde
    # os steps anteriores deste script também só simularam (nada foi escrito
    # ainda), delegar incondicionalmente faria o preflight completo
    # (`./bootstrap.sh --dry-run`) abortar com erro real do script delegado,
    # em vez de só mostrar o que seria feito.
    local prereqs_ready=true
    for f in "$DATA_BASE/redis/.bootstrap-creds" "$DATA_BASE/minio/.bootstrap-creds" "$DATA_BASE/kafka/.bootstrap-creds" "$DATA_BASE/vault/.bootstrap-creds.json"; do
        if ! sudo test -f "$f" 2>/dev/null; then
            prereqs_ready=false
            break
        fi
    done

    if $DRY_RUN; then
        if $prereqs_ready; then
            "$SCRIPT_DIR/seed-vault-secrets.sh" --dry-run
        else
            log_warn "Dry-run: pré-requisitos (.bootstrap-creds de redis/minio/kafka/vault) ainda não existem nesta VM — seed-vault-secrets.sh seria chamado numa execução real."
        fi
        return
    fi

    # seed-vault-secrets.sh recupera os client_secrets M2M via `kubectl exec`
    # no deployment do Keycloak — que este script NÃO instala (deploy próprio,
    # ver apps/keycloak-replica/README.md). Numa VM nova, rodando o bootstrap
    # do início ao fim, o Keycloak ainda não existe neste ponto; chamar o seed
    # incondicionalmente quebraria o fluxo default de ponta a ponta.
    if ! kubectl get deployment keycloak-replica -n uniplus &>/dev/null; then
        log_warn "deploy/keycloak-replica ausente no namespace uniplus — pulando seed de secrets."
        log_warn "Depois de instalar o Keycloak (ver apps/keycloak-replica/README.md), rodar manualmente:"
        log_warn "  $SCRIPT_DIR/seed-vault-secrets.sh"
        return
    fi

    "$SCRIPT_DIR/seed-vault-secrets.sh"
}

summary() {
    echo ""
    echo "============================================"
    log_success "Bootstrap lab-standalone-single concluído"
    echo "============================================"
    echo ""
    echo "Data services systemd:"
    echo "  systemctl status uniplus-{postgres,redis,minio,kafka}"
    echo ""
    echo "K3s:"
    echo "  kubectl get pods -A"
    echo ""
    if ! $SKIP_PLATFORM; then
        echo "Vault + ESO:"
        echo "  kubectl get pods -n vault -n external-secrets"
        echo "  kubectl get clustersecretstore vault-default"
        echo ""
        echo "Custódia das credenciais do Vault (PRIMEIRA EXECUÇÃO):"
        echo "  1. Ler:        sudo cat $DATA_BASE/vault/.bootstrap-creds.json"
        echo "  2. Custodiar:  fora do repo, gestor institucional"
        echo ""
    fi
    echo "Próximo passo (fora deste script — ver READMEs):"
    echo "  apps/uniplus-api-host/README.md   — build+import da imagem + deploy"
    echo "  apps/uniplus-api-portal/README.md — role+db Postgres + deploy"
}

# ============================================================================
# Main
# ============================================================================
echo "============================================"
echo "  Uni+ Lab Standalone Single Bootstrap"
echo "  Dry-run: $DRY_RUN"
echo "  Skip platform (Vault/ESO): $SKIP_PLATFORM"
echo "============================================"
echo ""

step_install_docker
step_install_k3s
step_install_helm
step_setup_postgres
step_setup_redis
step_setup_minio
step_setup_kafka

if $SKIP_PLATFORM; then
    log_warn "Pulando Vault/ESO (--skip-platform)."
else
    step_deploy_vault
    step_init_unseal_vault
    step_configure_vault_auth
    step_deploy_eso
    step_seed_secrets
fi

summary
