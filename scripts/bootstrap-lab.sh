#!/usr/bin/env bash
# ============================================================================
# bootstrap-lab.sh
#
# Provisiona o laboratório Uni+ em uma máquina Linux do zero.
#
# Uso:
#   ./bootstrap-lab.sh --role=sp1     # máquina Ryzen
#   ./bootstrap-lab.sh --role=sp2     # máquina i7
#   ./bootstrap-lab.sh --role=witness # apenas o container witness (na i7)
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============== Defaults ==============
ROLE=""
SKIP_K3S=false
SKIP_DOCKER=false
SKIP_CLOUDFLARED=true   # opcional, requer login interativo
DRY_RUN=false

# ============== Logging helpers ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

usage() {
    cat <<EOF
Uso: $0 --role={sp1|sp2|witness} [opções]

Roles:
  sp1       Configura a máquina principal (Ryzen 9950X — Arch Linux)
  sp2       Configura a máquina secundária (Core i7 — Ubuntu Server)
  witness   Configura apenas o container witness UNIFESSPA (na i7)

Opções:
  --skip-k3s          Pula instalação do K3s
  --skip-docker       Pula instalação do Docker
  --enable-cloudflared Inclui setup do Cloudflare Tunnel (requer login)
  --dry-run           Apenas mostra o que seria feito
  -h, --help          Esta mensagem

Exemplos:
  $0 --role=sp1
  $0 --role=sp2 --enable-cloudflared
  $0 --role=witness
EOF
    exit 0
}

# ============== Parse args ==============
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role=*) ROLE="${1#*=}"; shift ;;
        --skip-k3s) SKIP_K3S=true; shift ;;
        --skip-docker) SKIP_DOCKER=true; shift ;;
        --enable-cloudflared) SKIP_CLOUDFLARED=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) log_error "Opção inválida: $1"; usage ;;
    esac
done

if [[ -z "$ROLE" ]]; then
    log_error "Role obrigatório (--role=sp1|sp2|witness)"
    usage
fi

# ============== Helpers ==============
run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$*"
    fi
}

detect_os() {
    if [[ -f /etc/arch-release ]]; then
        echo "arch"
    elif grep -qi ubuntu /etc/os-release 2>/dev/null; then
        echo "ubuntu"
    else
        echo "unknown"
    fi
}

# ============== Steps ==============

step_check_prerequisites() {
    log_info "Verificando pré-requisitos..."
    
    local os
    os=$(detect_os)
    log_info "Sistema operacional: $os"
    
    if [[ "$os" == "unknown" ]]; then
        log_error "Sistema operacional não suportado. Use Arch Linux ou Ubuntu Server."
        exit 1
    fi
    
    if [[ $EUID -eq 0 ]]; then
        log_error "Não execute como root. Use sudo quando necessário."
        exit 1
    fi
    
    # Verificar comandos essenciais
    for cmd in curl git; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "Comando '$cmd' não encontrado. Instale antes de continuar."
            exit 1
        fi
    done
    
    log_success "Pré-requisitos OK."
}

step_install_docker() {
    if $SKIP_DOCKER; then
        log_warn "Pulando instalação do Docker (--skip-docker)"
        return
    fi
    
    if command -v docker &> /dev/null; then
        log_success "Docker já instalado: $(docker --version)"
        return
    fi
    
    log_info "Instalando Docker..."
    
    local os
    os=$(detect_os)
    
    if [[ "$os" == "ubuntu" ]]; then
        run "curl -fsSL https://get.docker.com | sudo sh"
        run "sudo usermod -aG docker $USER"
    elif [[ "$os" == "arch" ]]; then
        run "sudo pacman -Sy --noconfirm docker docker-compose"
        run "sudo systemctl enable --now docker"
        run "sudo usermod -aG docker $USER"
    fi
    
    log_warn "Docker instalado. Pode ser necessário fazer logout/login para aplicar grupo 'docker'."
    log_success "Docker pronto."
}

step_install_k3s() {
    if $SKIP_K3S; then
        log_warn "Pulando instalação do K3s (--skip-k3s)"
        return
    fi
    
    if [[ "$ROLE" == "witness" ]]; then
        log_info "Role 'witness' não precisa de K3s. Pulando."
        return
    fi
    
    if command -v k3s &> /dev/null; then
        log_success "K3s já instalado: $(k3s --version | head -1)"
        return
    fi
    
    log_info "Instalando K3s (cluster independente para $ROLE)..."
    
    local node_name="uniplus-$ROLE"
    local node_ip
    node_ip=$(hostname -I | awk '{print $1}')
    
    run "curl -sfL https://get.k3s.io | sh -s - \
        --node-name $node_name \
        --cluster-init \
        --tls-san $node_name \
        --tls-san $node_ip \
        --disable servicelb \
        --write-kubeconfig-mode 644"
    
    # Configurar kubectl local
    run "mkdir -p $HOME/.kube"
    run "sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config"
    run "sudo chown $(id -u):$(id -g) $HOME/.kube/config"
    
    log_success "K3s instalado e operacional."
}

step_install_helm() {
    if command -v helm &> /dev/null; then
        log_success "Helm já instalado: $(helm version --short)"
        return
    fi
    
    log_info "Instalando Helm..."
    run "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
    log_success "Helm instalado."
}

step_install_argocd() {
    if [[ "$ROLE" == "witness" ]]; then
        return
    fi
    
    log_info "Instalando ArgoCD..."
    
    run "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -"
    run "kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
    
    log_info "Aguardando ArgoCD subir..."
    run "kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd"
    
    log_info "Senha inicial do admin do ArgoCD:"
    run "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo ""
    
    log_success "ArgoCD instalado."
}

step_setup_witness() {
    if [[ "$ROLE" != "witness" ]]; then
        return
    fi
    
    log_info "Configurando container witness UNIFESSPA simulada..."
    
    run "docker network create --subnet 172.30.0.0/16 unifesspa-sim 2>/dev/null || true"
    
    log_warn "Witness setup ainda não implementado totalmente. Veja docs/SETUP.md seção 9."
    log_info "Próximos passos manuais:"
    echo "  1. cd $REPO_ROOT/data/witness"
    echo "  2. Criar docker-compose.yml conforme SETUP.md"
    echo "  3. docker compose up -d"
}

step_setup_cloudflared() {
    if $SKIP_CLOUDFLARED; then
        log_warn "Pulando Cloudflare Tunnel (use --enable-cloudflared para incluir)"
        return
    fi
    
    if command -v cloudflared &> /dev/null; then
        log_success "cloudflared já instalado"
    else
        log_info "Instalando cloudflared..."
        run "curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -o /tmp/cloudflared"
        run "sudo install /tmp/cloudflared /usr/local/bin/cloudflared"
    fi
    
    log_warn "Configuração interativa do Cloudflare Tunnel:"
    echo "  Execute manualmente:"
    echo "    cloudflared tunnel login"
    echo "    cloudflared tunnel create uniplus-lab-$ROLE"
    echo "  Veja docs/SETUP.md seção 7 para detalhes."
}

step_summary() {
    echo ""
    echo "============================================"
    log_success "Bootstrap completo para role: $ROLE"
    echo "============================================"
    echo ""
    echo "Próximos passos:"
    echo ""
    
    if [[ "$ROLE" == "sp1" || "$ROLE" == "sp2" ]]; then
        echo "  1. Verificar K3s:"
        echo "       kubectl get nodes"
        echo ""
        echo "  2. Acessar ArgoCD:"
        echo "       kubectl port-forward -n argocd svc/argocd-server 8080:443"
        echo "       open https://localhost:8080  (admin / senha mostrada acima)"
        echo ""
        echo "  3. Provisionar componentes do host (Postgres, Kafka, MinIO):"
        echo "       cd $REPO_ROOT/data/postgres && docker compose up -d"
        echo "       cd $REPO_ROOT/data/kafka && docker compose up -d"
        echo "       cd $REPO_ROOT/data/minio && docker compose up -d"
        echo ""
        echo "  4. Aplicar manifests do ArgoCD (este cluster):"
        echo "       kubectl apply -f $REPO_ROOT/argocd/project.yaml"
        echo "       kubectl apply -f $REPO_ROOT/argocd/applicationset.yaml"
        echo ""
        echo "  5. Validar instalação:"
        echo "       $REPO_ROOT/scripts/validate-cluster.sh"
    fi
    
    if [[ "$ROLE" == "witness" ]]; then
        echo "  1. Criar docker-compose.yml em data/witness/"
        echo "  2. docker compose up -d"
        echo "  3. Verificar quórum etcd dos clusters Patroni"
    fi
    
    echo ""
    echo "Documentação: $REPO_ROOT/docs/SETUP.md"
}

# ============== Main ==============
echo "============================================"
echo "  Uni+ Lab Bootstrap"
echo "  Role: $ROLE"
echo "  Dry-run: $DRY_RUN"
echo "============================================"
echo ""

step_check_prerequisites
step_install_docker
step_install_k3s
step_install_helm
step_install_argocd
step_setup_witness
step_setup_cloudflared
step_summary
