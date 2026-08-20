#!/usr/bin/env bash
# ============================================================================
# bootstrap.sh — hml-standalone-single
#
# Bootstrap da fundação real no ambiente HML da UNIFESSPA (VM dedicada
# `192.168.21.134`, rede interna, VPN-only — Epic #434, Feature #435, Story
# #442). Adaptado de scripts/lab-standalone-single/bootstrap.sh (já validado
# no lab e no spike de PathPrefix executado na própria VM real — ver
# docs/validacao/spike-pathprefix-hml-2026-07-12.md), mas com uma diferença
# estrutural importante: este ambiente é GitOps/ArgoCD (environments/
# hml-standalone-single/values.yaml, Story #439), não aplicação manual via
# `helm install/upgrade -f` como o lab.
#
# Por isso este script cobre só o que precisa acontecer ANTES do cluster
# existir no ArgoCD — os fixes de DNS achados no spike (Docker + CoreDNS,
# ambos com nameserver do host inalcançável), Docker, K3s, Helm, ArgoCD
# (self-hosted, mesmo padrão de scripts/bootstrap-standalone.sh
# --role=standalone-k8s), Postgres (roles+databases do Keycloak e do
# Apicurio Registry), Kafka (Feature 1 do Epic #434) e o certificado TLS
# autoassinado provisório que Traefik/Keycloak/Apicurio Registry precisam.
# Vault, ESO, Traefik, Keycloak e Apicurio Registry em si NÃO são
# instalados por este script — o ApplicationSet os cria assim que o cluster
# for registrado no ArgoCD (ver summary() no final e docs/RUNBOOKS.md §8.3
# para o procedimento, idêntico ao já usado em standalone-compact). O init/
# unseal do Vault, a configuração de auth/policy/role e o seed dos secrets
# que Keycloak/Apicurio esperam também ficam fora deste script — são
# procedimento manual pós-registro, mesmo padrão de docs/RUNBOOKS.md §8.4
# (não scriptado nem em standalone-compact real).
#
# Uso:
#   ./bootstrap.sh [--dry-run]
#
# Pré-requisitos: Ubuntu 24.04 LTS, usuário com sudo sem senha, não rodar
# como root, executado de dentro da rede/VPN da UNIFESSPA (a VM não tem IP
# público).
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Mesmo gotcha documentado em scripts/lab-standalone-single/bootstrap.sh: o
# instalador oficial do K3s cria /usr/local/bin/kubectl como symlink pro
# binário unificado, que usa /etc/rancher/k3s/k3s.yaml como kubeconfig
# default nativo — ignora ~/.kube/config a menos que KUBECONFIG seja
# exportado explicitamente.
export KUBECONFIG="$HOME/.kube/config"

# ============== Versões pinadas ==============
# Mesmas versões de scripts/lab-standalone-single/bootstrap.sh (corrigidas
# em 2026-07-12 — K3s 1.31.4 estava EOL desde nov/2025, ver
# docs/validacao/spike-pathprefix-hml-2026-07-12.md) e de
# scripts/bootstrap-standalone.sh (ARGOCD_VERSION — v2.14→v3.x é salto de
# major version com guia de migração dedicado, fora do escopo de uma
# atualização de rotina).
#
# ATENÇÃO: a matriz oficial de compatibilidade do ArgoCD 2.14.x lista
# Kubernetes testado até 1.31 (K3s 1.36 embute 1.36) — 5 minors de gap não
# validado pelo upstream. Não é bloqueante por si só (ArgoCD historicamente
# tolera K8s mais novo na prática), mas reconfirmar contra
# https://argo-cd.readthedocs.io/en/release-2.14/operator-manual/installation/#tested-versions
# antes do bootstrap real (#445); se houver falha do controller/CRDs
# relacionada à versão do K8s, o fallback é fixar um K3s dentro da matriz
# testada só para esta VM, sem alterar o pin de lab/standalone-compact.
K3S_VERSION="v1.36.2+k3s1"
HELM_VERSION="v3.21.2"
ARGOCD_VERSION="v2.14.3"

# ============== Defaults ==============
DRY_RUN=false

DATA_BASE="/var/lib/uniplus"
TLS_NAMESPACE="uniplus"
TLS_SECRET_NAME="uniplus-hml-unifesspa-tls"
# 9 hostnames de docs/RUNBOOKS.md §21.2, já registrados pela CTIC
# (issue #486) — substitui o SAN provisório *.${NODE_IP}.nip.io usado
# antes do DNS real existir.
TLS_SANS="DNS:uniplus-hml.unifesspa.edu.br,DNS:uniplus-api-hml.unifesspa.edu.br,DNS:uniplus-oidc-hml.unifesspa.edu.br,DNS:geo-api-hml.unifesspa.edu.br,DNS:grafana-hml.unifesspa.edu.br,DNS:kafka-ui-hml.unifesspa.edu.br,DNS:apicurio-hml.unifesspa.edu.br,DNS:redis-ui-hml.unifesspa.edu.br,DNS:minio-hml.unifesspa.edu.br"

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
    # `postgis/postgis:18-3.6` (step_setup_postgres) só publica manifest
    # amd64 (confirmado via `docker manifest inspect`) — arm64 seguiria até
    # Docker/K3s/ArgoCD instalarem para só então falhar tarde, no primeiro
    # `docker run` do Postgres. Falhar cedo aqui evita esse desperdício.
    aarch64) log_error "Arquitetura arm64 não suportada — postgis/postgis:18-3.6 (step_setup_postgres) só publica imagem amd64."; exit 1 ;;
    *)       log_error "Arquitetura não suportada: $(uname -m). Esperado x86_64."; exit 1 ;;
esac

usage() {
    cat <<EOF
Uso: $0 [--dry-run]

Bootstrap da fundação (Docker, K3s, Helm, ArgoCD, Postgres, Kafka, cert TLS
provisório) da VM real do hml-standalone-single. Vault/ESO/Traefik/Keycloak/
Apicurio Registry NÃO são instalados por este script — ver "Próximos
passos" no resumo final.

Opções:
  --dry-run    Mostra o que seria feito, sem aplicar.
  -h, --help   Esta mensagem.

Exemplos:
  $0 --dry-run
  $0
EOF
}

for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=true ;;
        -h|--help)  usage; exit 0 ;;
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

# Capturado UMA VEZ, antes de qualquer step que crie interfaces de rede
# adicionais (docker0 do Docker, cni0/flannel do K3s) — `hostname -I` listaria
# essas IPs privadas também, e tanto `awk '{print $1}'` (ordem de listagem
# não garantida) quanto o grep por range privado de
# scripts/lab-standalone-single/setup-kafka.sh poderiam pegar a interface
# errada se computados depois. `ip route get` resolve pela rota default —
# sempre a interface real de saída, nunca uma bridge/CNI local.
NODE_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}')
if [[ -z "$NODE_IP" ]]; then
    log_error "Não consegui determinar o IP real do host via 'ip route get 8.8.8.8'."
    exit 1
fi
log_info "IP real do host (via rota default): $NODE_IP"

# ============================================================================
# Steps — Docker + K3s + Helm + ArgoCD
# ============================================================================

# DNS quebrado, específico desta VM — achado empírico do spike de PathPrefix
# (docs/validacao/spike-pathprefix-hml-2026-07-12.md, seção 2, achados 1-2):
# `/etc/resolv.conf` do host (systemd-resolved) lista um nameserver IPv4
# inalcançável; o Docker extrai o nameserver "legacy" e usa esse, quebrando
# `apt-get`/pull de imagem dentro de builds e containers. Fix: nameservers
# explícitos no daemon.json do Docker. O spike preservou esse fix ao
# derrubar a VM ("mantido de propósito"), mas o script reaplica
# idempotentemente — cobre o caso de reimagem/nova VM onde o fix não existe.
step_fix_docker_dns() {
    local daemon_json="/etc/docker/daemon.json"

    if $DRY_RUN; then
        echo "[DRY-RUN] Faria merge de dns: [1.1.1.1, 8.8.8.8] em $daemon_json, preservando outras chaves (+ restart docker se mudou)"
        return
    fi

    if sudo test -f "$daemon_json" && sudo grep -q '"dns"' "$daemon_json" 2>/dev/null; then
        log_success "$daemon_json já tem DNS explícito — preservando."
        return
    fi

    log_info "Configurando DNS explícito no Docker (achado do spike — nameserver do host inalcançável)..."
    # Merge via python3 (sempre presente em Ubuntu Server 24.04, mesma
    # dependência já usada em scripts/lab-standalone-single/bootstrap.sh para
    # parsear `vault status -format=json`) — NUNCA sobrescrever o arquivo
    # inteiro: se já existir com outras chaves (registry mirrors, insecure-
    # registries, logging, storage-driver), um `tee` sem merge apagaria essas
    # configurações.
    local merged
    merged=$(sudo python3 -c "
import json, sys
path = '$daemon_json'
try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {}
data['dns'] = ['1.1.1.1', '8.8.8.8']
print(json.dumps(data, indent=2))
")
    printf '%s\n' "$merged" | sudo tee "$daemon_json" >/dev/null
    if systemctl is-active --quiet docker 2>/dev/null; then
        sudo systemctl restart docker
    fi
    log_success "Docker DNS configurado (demais chaves de $daemon_json preservadas)."
}

step_install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        log_success "Docker já instalado: $(docker --version)"
    else
        log_info "Instalando Docker + Compose v2..."
        run "sudo apt-get update -qq"
        run "sudo apt-get install -y docker.io docker-compose-v2"
        run "sudo systemctl enable --now docker"
        run "sudo usermod -aG docker $USER"
        log_warn "Logout/login necessário para aplicar o grupo 'docker' (se ainda não estiver nele)."
        log_success "Docker instalado."
    fi

    step_fix_docker_dns
}

step_install_k3s() {
    if command -v k3s &>/dev/null; then
        log_success "K3s já instalado: $(k3s --version | head -1)"
    else
        log_info "Instalando K3s $K3S_VERSION (host combinado, IP: $NODE_IP)..."

        # --disable traefik/servicelb: platform/traefik/ (ArgoCD, pós-registro)
        # é o IngressController real deste ambiente — o Traefik/ServiceLB
        # bundled do K3s competiria pelo bind 80/443. O kubeconfig contém
        # credenciais administrativas: restringi-lo a root e copiar uma
        # versão privada para o operador autorizado abaixo.
        run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
            --node-name uniplus-hml \
            --tls-san $NODE_IP \
            --disable servicelb \
            --disable traefik \
            --write-kubeconfig-mode 600"
    fi

    # Em reexecuções, o K3s pode ter sido instalado por uma versão anterior
    # do bootstrap que usava modo 0644. Não depender apenas da flag do
    # instalador mantém o kubeconfig administrativo restrito também nesses
    # hosts já existentes.
    run "sudo chmod 600 /etc/rancher/k3s/k3s.yaml"
    run "install -d -m 700 $HOME/.kube"
    run "sudo install -m 600 -o $(id -u) -g $(id -g) /etc/rancher/k3s/k3s.yaml $HOME/.kube/config"
    log_success "K3s pronto."
}

# Mesmo achado do spike (docs/validacao/spike-pathprefix-hml-2026-07-12.md,
# seção 2, achado 2): o CoreDNS do cluster herda o `forward . /etc/resolv.conf`
# default, que aponta pro mesmo nameserver IPv4 inalcançável do host —
# `SERVFAIL` ao resolver hostnames de dentro de pods (nip.io, registries de
# imagem, repos Helm). A VM do spike foi completamente derrubada ao final
# (K3s desinstalado), então este fix NÃO sobrevive — precisa ser reaplicado
# a cada bootstrap novo, diferente do fix do Docker acima.
step_patch_coredns() {
    if $DRY_RUN; then
        echo "[DRY-RUN] kubectl patch configmap coredns -n kube-system (forward . 1.1.1.1 8.8.8.8)"
        echo "[DRY-RUN] kubectl rollout restart deployment/coredns -n kube-system"
        return
    fi

    log_info "Aguardando CoreDNS ficar disponível para patch..."
    # `kubectl wait --for=condition=available` exige que o objeto JÁ EXISTA —
    # falha imediatamente com NotFound se o deployment ainda não foi criado,
    # não espera pela criação. Logo após `systemctl start k3s`, o deploy
    # controller do K3s ainda não aplicou os addons bundled (coredns,
    # local-path-provisioner, metrics-server) — leva alguns segundos.
    # Achado real na execução contra a VM (não reproduzível em dry-run, que
    # nunca consulta a API do K3s).
    local attempts=0
    until kubectl get deployment coredns -n kube-system &>/dev/null; do
        attempts=$(( attempts + 1 ))
        if (( attempts >= 24 )); then
            log_error "Deployment coredns não apareceu em 120s. Ver: kubectl get pods -n kube-system"
            exit 1
        fi
        sleep 5
    done
    kubectl wait --for=condition=available --timeout=120s deployment/coredns -n kube-system

    local corefile
    corefile=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
    if echo "$corefile" | grep -q 'forward \. 1\.1\.1\.1 8\.8\.8\.8'; then
        log_success "CoreDNS já usa forwarders explícitos — preservando."
        return
    fi

    log_info "Corrigindo CoreDNS (forward . /etc/resolv.conf -> 1.1.1.1 8.8.8.8, achado do spike)..."
    local patched_corefile
    patched_corefile=$(echo "$corefile" | sed 's/forward \. \/etc\/resolv\.conf/forward . 1.1.1.1 8.8.8.8/')
    kubectl create configmap coredns -n kube-system \
        --from-literal=Corefile="$patched_corefile" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl rollout restart deployment/coredns -n kube-system
    kubectl rollout status deployment/coredns -n kube-system --timeout=120s
    log_success "CoreDNS corrigido (forwarders explícitos)."
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

step_install_argocd() {
    # Mesmo padrão de scripts/bootstrap-standalone.sh (step_install_argocd) —
    # ArgoCD self-hosted no próprio cluster que gerencia (registrado via
    # `argocd cluster add ... --in-cluster` no procedimento pós-script, ver
    # summary()). Idempotente: reaplicar o manifest upstream em cima de uma
    # instalação existente é um no-op ou upgrade in-place, conforme a versão
    # já instalada.
    log_info "Instalando ArgoCD $ARGOCD_VERSION..."

    run "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -"
    # --server-side evita o limite de 262144 bytes nas anotações dos CRDs do
    # ArgoCD no K3s; --force-conflicts resolve conflitos de field manager em
    # re-runs após falha client-side.
    run "kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

    log_info "Aguardando ArgoCD ficar disponível (até 5 min)..."
    run "kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server \
        deployment/argocd-repo-server \
        deployment/argocd-applicationset-controller \
        -n argocd"

    # K3s expõe .status.terminatingReplicas em Deployment/StatefulSet a partir
    # da 1.32 — campo que o schema OpenAPI embutido no binário do ArgoCD ainda
    # não reconhece nas versões testadas contra K3s <=1.31. Com
    # ServerSideApply=true (necessário: CRDs do external-secrets/cert-manager
    # estourariam os 262144 bytes de anotação do client-side apply), o ArgoCD
    # usa por padrão a estratégia "structured merge diff" local, que tenta
    # tipar o recurso live contra esse schema embutido e falha com
    # ComparisonError assim que encontra o campo — travando toda a Application
    # em Sync Status "Unknown" e impedindo até a criação de recursos novos
    # dentro dela. Server-Side Diff delega o cálculo do diff a um dry-run no
    # próprio API server (que conhece o campo de verdade), contornando o gap.
    log_info "Habilitando Server-Side Diff no controller do ArgoCD..."
    run "kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
        -p '{\"data\":{\"controller.diff.server.side\":\"true\"}}'"
    run "kubectl -n argocd rollout restart statefulset/argocd-application-controller"
    run "kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s"

    log_success "ArgoCD instalado."
}

# ============================================================================
# Step — Postgres (mesmo padrão systemd/LoadCredential de
# scripts/lab-standalone-single/bootstrap.sh — imagem postgis/postgis em vez
# de postgres:18-alpine porque módulos futuros do Epic #434 (unifesspa-geo-api,
# Feature 2+) vão exigir PostGIS; adotar já evita migração disruptiva depois.
#
# Diferente de scripts/bootstrap-standalone.sh (step_data_setup_postgres),
# que cria o role/database do Keycloak via bind mount em
# /docker-entrypoint-initdb.d: essa imagem (postgis/postgis) já embute NESSE
# MESMO path o script que cria template_postgis + carrega as extensions —
# um bind mount nosso ali esconderia esse script da imagem e o cluster
# subiria sem PostGIS (mesmo gotcha documentado no header de
# environments/lab-standalone-single/README.md). Por isso role/database do
# Keycloak e do Apicurio são criados via `docker exec ... psql` DEPOIS do
# cluster já estar pronto (mesmo padrão de step_data_setup_apicurio_db em
# scripts/bootstrap-standalone.sh), não via init script.
# ============================================================================

step_setup_postgres() {
    log_info "Configurando Postgres 18 + PostGIS 3.6 systemd..."

    local creds_file="$DATA_BASE/postgres/.bootstrap-creds"
    local cred_dir="/etc/credstore"
    local cred_file="$cred_dir/uniplus-postgres-password"
    local unit_file="/etc/systemd/system/uniplus-postgres.service"

    run "sudo mkdir -p $DATA_BASE/postgres/data"
    run "sudo chown 70:70 $DATA_BASE/postgres/data"

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
Description=Uni+ Postgres 18 + PostGIS 3.6 (hml standalone-single)
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
        echo "[DRY-RUN] systemctl start uniplus-postgres + aguardaria pg_isready (até 5min)"
    elif sudo systemctl is-active --quiet uniplus-postgres; then
        log_success "uniplus-postgres já ativo — preservando state (sem restart)."
    else
        sudo systemctl start uniplus-postgres
        log_info "Aguardando Postgres aceitar conexões (cold start com pull de imagem pode levar minutos)..."
        # 60 tentativas × 5s = 5min — 60s não bastava no spike (pull da imagem
        # postgis/postgis, ~1-2GB na 1ª vez, mais o ciclo initdb+restart dos
        # entrypoints oficiais excedeu o timeout fixo anterior; achado #4 do
        # spike, não corrigido lá por não ser bloqueante — corrigido aqui.
        #
        # `-h 127.0.0.1` força o probe via TCP, não Unix socket: num data dir
        # novo, o entrypoint oficial do Postgres (herdado pelo postgis/postgis)
        # sobe um servidor TEMPORÁRIO socket-only (listen_addresses='') pra
        # rodar os scripts de init, para esse servidor, e só DEPOIS sobe o
        # servidor final com listen_addresses=0.0.0.0 (o que o unit systemd
        # configura). `pg_isready` sem -h usa o socket local por padrão — sem
        # forçar TCP, o probe passaria contra o servidor temporário, e
        # step_setup_postgres_databases correria o risco de bater exatamente
        # na janela entre o temporário cair e o final subir (connection
        # refused).
        local attempts=0
        until sudo docker exec uniplus-postgres pg_isready -h 127.0.0.1 -U postgres &>/dev/null; do
            attempts=$(( attempts + 1 ))
            if (( attempts >= 60 )); then
                log_error "Postgres não ficou ready em 5min. Ver: sudo journalctl -u uniplus-postgres -n 50"
                exit 1
            fi
            sleep 5
        done
        log_success "uniplus-postgres ativo + pg_isready OK."
    fi

    step_setup_postgres_databases
}

# Cria role+database do Keycloak e do Apicurio Registry — os dois apps
# habilitados nesta fase (environments/hml-standalone-single/values.yaml,
# Story #439) que esperam um Postgres já provisionado. Via `docker exec ...
# psql` (não init script — ver comentário no topo da seção). Padrão idêntico
# ao de step_data_setup_apicurio_db em scripts/bootstrap-standalone.sh:
# detecta role pré-existente (evita ALTER ROLE silencioso desincronizando
# senha do Vault), \if block do psql em vez de DO $$ (não interpola
# :'var' dentro de dollar-quoted strings — reproduzido lá, Codex P1 round 2),
# senhas via env var do `docker exec` (não argv — vazaria via
# /proc/<pid>/cmdline).
step_setup_postgres_databases() {
    if $DRY_RUN; then
        echo "[DRY-RUN] Criaria roles+databases 'keycloak' e 'apicurio' via psql (idempotente)"
        return
    fi

    local pg_creds="$DATA_BASE/postgres/.bootstrap-creds"
    local super_pw
    super_pw=$(sudo grep '^super_pw=' "$pg_creds" | cut -d= -f2)
    if [[ -z "$super_pw" ]]; then
        log_error "super_pw vazio em $pg_creds. Abortando setup de databases."
        exit 1
    fi

    _setup_app_database "keycloak" "$super_pw"
    _setup_app_database "apicurio" "$super_pw"
    unset super_pw
    log_success "Databases de aplicação (keycloak, apicurio) prontas."
}

# $1 = nome do role/database/creds file (ex.: "keycloak", "apicurio")
# $2 = super_pw do Postgres
#
# Senhas passadas via `docker exec --env-file <tmp>` (não `-e NAME=value`):
# `-e` expõe o valor no argv do processo `docker` no HOST (visível via
# `ps`/`/proc/<pid>/cmdline` a qualquer usuário local enquanto o comando
# roda) — diferente de `/proc/<pid>/environ` (root-only, mode 400) do
# processo DENTRO do container, que é o que o comentário original de
# scripts/bootstrap-standalone.sh (step_data_setup_apicurio_db) endereça.
# --env-file lê de um arquivo (mode 600, shredded ao final) e não aparece em
# nenhum argv, nem do container nem do host.
#
# Corpo inteiro roda num subshell com trap EXIT próprio — chamado 2x (keycloak,
# apicurio) por step_setup_postgres_databases; um `trap ... EXIT` direto na
# função (sem subshell) seria substituído pela segunda chamada antes de
# disparar para a primeira (trap EXIT não é function-scoped em bash), e
# `trap ... RETURN` não dispara em abort por `set -e` no meio do corpo
# (mesmo gotcha corrigido em step_generate_tls_secret). Falha dentro do
# subshell propaga como retorno não-zero da função, `set -e` do chamador
# aborta o script normalmente.
_setup_app_database() (
    local app_name="$1"
    local super_pw="$2"
    local app_creds="$DATA_BASE/postgres/.bootstrap-creds-$app_name"

    local envfile
    envfile=$(sudo mktemp /etc/credstore/pg-envfile-XXXXXX)
    trap 'sudo shred -u "$envfile" 2>/dev/null || true' EXIT
    sudo chmod 600 "$envfile"
    printf 'PGPASSWORD=%s\n' "$super_pw" | sudo tee "$envfile" >/dev/null

    local role_exists=false
    if sudo docker exec --env-file "$envfile" uniplus-postgres \
         psql -U postgres -tAc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='$app_name'" 2>/dev/null \
         | grep -q '^1$'; then
        role_exists=true
    fi

    if sudo test -f "$app_creds" 2>/dev/null; then
        log_success "Bootstrap creds de '$app_name' já existentes — preservando senha."
    elif $role_exists; then
        # Guard: role já existe no Postgres mas o creds file foi shredded
        # (custódia no Vault já feita). Regenerar agora rodaria ALTER ROLE
        # silencioso, desincronizando Postgres da senha custodiada.
        log_error "$app_creds ausente, mas role Postgres '$app_name' já existe."
        log_error "Regenerar a senha agora desincronizaria Postgres do Vault."
        log_error "Restaure $app_creds a partir do Vault antes de re-rodar."
        exit 1
    else
        log_info "Gerando senha de '$app_name' (256 bits)..."
        local app_pw
        app_pw=$(openssl rand -hex 32)
        sudo tee "$app_creds" >/dev/null <<EOF
${app_name}_pw=$app_pw
EOF
        sudo chown root:root "$app_creds"
        sudo chmod 600 "$app_creds"
        unset app_pw
        log_warn "Senha de '$app_name' gerada em $app_creds. Custódia obrigatória — nunca commitar."
    fi

    local app_pw
    app_pw=$(sudo grep "^${app_name}_pw=" "$app_creds" | cut -d= -f2)
    if [[ -z "$app_pw" ]]; then
        log_error "${app_name}_pw vazio em $app_creds. Abortando."
        exit 1
    fi
    printf 'PGPASSWORD=%s\nAPP_PW=%s\n' "$super_pw" "$app_pw" | sudo tee "$envfile" >/dev/null

    sudo docker exec \
        --env-file "$envfile" \
        -i uniplus-postgres \
        psql -U postgres -v ON_ERROR_STOP=1 <<SQL 2>&1 | tail -10
\getenv app_pw APP_PW
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '$app_name') AS role_exists \gset
\if :role_exists
   ALTER ROLE $app_name WITH LOGIN PASSWORD :'app_pw';
\else
   CREATE ROLE $app_name WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif
SQL

    sudo docker exec --env-file "$envfile" uniplus-postgres \
        psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$app_name'" 2>/dev/null \
        | grep -q 1 \
      || sudo docker exec --env-file "$envfile" uniplus-postgres \
        psql -U postgres -c "CREATE DATABASE $app_name OWNER $app_name ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0" 2>&1 | tail -3

    sudo docker exec --env-file "$envfile" uniplus-postgres \
        psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE $app_name TO $app_name" >/dev/null 2>&1
)

step_setup_kafka() {
    log_info "Configurando Kafka (delegando para setup-kafka.sh)..."
    # DATA_HOST_IP explícito (NODE_IP, capturado ANTES de Docker/K3s criarem
    # interfaces adicionais) — sem isso, setup-kafka.sh auto-detectaria via
    # seu próprio `hostname -I | grep <range privado> | head -1`, que neste
    # ponto do fluxo (Docker + K3s já instalados) já lista docker0/cni0 além
    # da interface real, com risco real de pegar a IP errada.
    if $DRY_RUN; then
        DATA_HOST_IP="$NODE_IP" "$SCRIPT_DIR/setup-kafka.sh" --dry-run
    else
        DATA_HOST_IP="$NODE_IP" "$SCRIPT_DIR/setup-kafka.sh"
    fi
}

# ============================================================================
# Step — Certificado TLS autoassinado provisório (docs/RUNBOOKS.md §21.1:
# obrigatório antes de qualquer usuário real, aceitável como paliativo de
# bring-up administrativo). Mesmo procedimento manual documentado em
# environments/lab-standalone-single/README.md, scriptado e tornado
# idempotente — Traefik/Keycloak/Apicurio Registry/uniplus-web
# (ApplicationSet, pós-registro no ArgoCD) esperam o Secret
# `$TLS_SECRET_NAME` já existente no namespace `uniplus` na primeira
# sincronização.
#
# Diferente do lab: aqui NÃO copiamos o PEM para nenhum values.yaml (a
# fundação desta Story não inclui os apps .NET que precisariam de
# customCA.certPEM — ver comentário em
# environments/hml-standalone-single/values.yaml) — só o Secret Kubernetes,
# consumido diretamente pelos IngressRoute via `tls.secretName`.
# ============================================================================

step_generate_tls_secret() {
    log_info "Gerando certificado TLS autoassinado provisório..."

    if $DRY_RUN; then
        echo "[DRY-RUN] kubectl create namespace $TLS_NAMESPACE (idempotente)"
        echo "[DRY-RUN] openssl req -x509 -newkey rsa:2048 ... SAN=$TLS_SANS"
        echo "[DRY-RUN] kubectl create secret tls $TLS_SECRET_NAME -n $TLS_NAMESPACE (se ainda não existir)"
        return
    fi

    kubectl create namespace "$TLS_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    if kubectl get secret "$TLS_SECRET_NAME" -n "$TLS_NAMESPACE" &>/dev/null; then
        log_success "Secret $TLS_SECRET_NAME já existe em $TLS_NAMESPACE — preservando."
        return
    fi

    # Subshell + trap EXIT (não RETURN): sob `set -e`, uma falha no meio do
    # bloco (openssl, kubectl create) sai do subshell sem passar por um
    # `return` normal — trap RETURN não dispara nesse caminho, deixando a
    # chave privada órfã em /tmp. trap EXIT roda em qualquer saída do
    # subshell (sucesso, erro, sinal), mesmo padrão já usado em
    # scripts/lab-standalone-single/bootstrap.sh (step_configure_vault_auth)
    # para material sensível. `kubectl create secret` (não idempotente) trocado
    # por gerar+aplicar via `apply`, seguro para re-run se a checagem acima
    # falhar por race entre dois bootstraps concorrentes.
    (
        tmpdir=$(mktemp -d)
        trap 'shred -u "$tmpdir"/*.key 2>/dev/null; rm -rf "$tmpdir"' EXIT
        chmod 700 "$tmpdir"

        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$tmpdir/tls.key" -out "$tmpdir/tls.crt" -days 825 \
            -subj "/CN=uniplus-hml.unifesspa.edu.br" \
            -addext "subjectAltName=$TLS_SANS" \
            >/dev/null 2>&1

        kubectl create secret tls "$TLS_SECRET_NAME" \
            --cert="$tmpdir/tls.crt" --key="$tmpdir/tls.key" -n "$TLS_NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
    )

    log_warn "Certificado autoassinado gerado (SAN: $TLS_SANS) — chave privada descartada após criar o Secret."
    log_success "Secret $TLS_SECRET_NAME criado em $TLS_NAMESPACE."

    # O Host mescla a CA no trust store durante o initContainer. Quando uma
    # recuperação recria este Secret, reiniciar o Deployment faz o init rodar
    # com o novo tls.crt; sem isso o emptyDir do Pod preservaria a CA antiga.
    kubectl get deployment -n "$TLS_NAMESPACE" -l app.kubernetes.io/name=uniplus-api-host -o name \
        | xargs -r kubectl -n "$TLS_NAMESPACE" rollout restart
}

summary() {
    echo ""
    echo "============================================"
    log_success "Bootstrap hml-standalone-single (fundação) concluído"
    echo "============================================"
    echo ""
    echo "Data services systemd:"
    echo "  systemctl status uniplus-{postgres,kafka}"
    echo ""
    echo "K3s + ArgoCD:"
    echo "  # Em uma nova sessão de operador, usar o kubeconfig privado:"
    echo "  export KUBECONFIG=$HOME/.kube/config"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -n argocd"
    echo "  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    echo "Próximos passos (fora deste script — Story #445):"
    echo "  1. Registrar o cluster no ArgoCD — CONTRATO: '--name in-cluster' explícito"
    echo "     (o Application/Service name do Vault gerado pelo ApplicationSet é o"
    echo "     nome do cluster, não o contexto kubeconfig — ver"
    echo "     environments/hml-standalone-single/values.yaml e o mesmo padrão já"
    echo "     usado em standalone-compact):"
    echo "       argocd cluster add <context> --in-cluster --name in-cluster \\"
    echo "         --label uniplus.io/managed=true --label environment=hml-standalone-single"
    echo ""
    echo "  2. Aplicar os manifests GitOps (ApplicationSet cria Vault/ESO/Traefik/"
    echo "     Keycloak/Apicurio Registry — os recursos aplicam normalmente, mas os"
    echo "     Pods de Vault/Keycloak/Apicurio ficam Degraded/Progressing até o"
    echo "     passo 3, já que o Vault sobe sealed/sem role e os apps dependem de"
    echo "     Secrets que só o ClusterSecretStore entrega):"
    echo "       kubectl apply -f $REPO_ROOT/argocd/project.yaml"
    echo "       kubectl apply -f $REPO_ROOT/argocd/applicationset.yaml"
    echo ""
    echo "  3. Init + unseal do Vault (Shamir 5/3 — ADR-014, NÃO o 1/1 do lab) +"
    echo "     configurar auth Kubernetes/policy/role external-secrets — mesmo"
    echo "     procedimento de docs/RUNBOOKS.md §8.4, aplicado a este Vault. Depois,"
    echo "     popular os secrets que Keycloak/Apicurio esperam via ExternalSecret"
    echo "     (mesmo padrão de scripts/lab-standalone-single/seed-vault-secrets.sh,"
    echo "     subconjunto desta fase — secret/standalone/postgres/{keycloak,apicurio}"
    echo "     com as senhas geradas em"
    echo "     $DATA_BASE/postgres/.bootstrap-creds-{keycloak,apicurio}, e"
    echo "     secret/standalone/keycloak/admin + secret/standalone/keycloak/clients/"
    echo "     apicurio-registry — este último só existe DEPOIS do primeiro"
    echo "     --import-realm do Keycloak, recuperado via kcadm)."
    echo ""
    echo "     Antes de considerar o Host disponível, executar NA VM, depois de"
    echo "     o Vault estar unsealed e a role external-secrets configurada:"
    echo "       $SCRIPT_DIR/provision-api-host-prerequisites.sh"
    echo "     O helper provisiona Redis/MinIO/Postgres, grava os paths Vault do"
    echo "     Host e cria somente a cópia runtime da chave local no Kubernetes."
    echo "     Isso é obrigatório antes de validar o Deployment GitOps do Host;"
    echo "     aguardar os ExternalSecrets do namespace uniplus sincronizarem."
    echo ""
    echo "  4. Validar convergência do ArgoCD (self-heal automático após o passo 3 —"
    echo "     reconcilia drift Git-vs-live; a disponibilidade de Vault/Keycloak/"
    echo "     Apicurio em si depende só do passo 3 estar completo):"
    echo "       argocd app list --selector environment=hml-standalone-single"
}

# ============================================================================
# Main
# ============================================================================
echo "============================================"
echo "  Uni+ HML Standalone Single Bootstrap"
echo "  Dry-run: $DRY_RUN"
echo "============================================"
echo ""

step_install_docker
step_install_k3s
step_patch_coredns
step_install_helm
step_install_argocd
step_setup_postgres
step_setup_kafka
step_generate_tls_secret

summary
