#!/usr/bin/env bash
# ============================================================================
# bootstrap-lab.sh
#
# Provisiona o laboratório Uni+ em uma máquina Linux do zero.
#
# Uso:
#   ./bootstrap-lab.sh --role=sp1   # máquina Ryzen — cluster K3s simulando SP1
#   ./bootstrap-lab.sh --role=sp2   # máquina i7    — cluster K3s simulando SP2
#   ./bootstrap-lab.sh --role=pa1   # máquina i7    — cluster K3s simulando PA1
#                                   # (em adição aos containers Docker do DC
#                                   # institucional simulado: etcd quorum,
#                                   # keycloak-master, minio-master, backup-target)
#
# Nota: --role=witness é alias DEPRECATED de --role=pa1, mantido para
# compatibilidade com a documentação anterior. Emite warning e prossegue.
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============== Versões pinadas (supply chain) ==============
# Atualizar ao promover o lab para nova versão estável validada.
K3S_VERSION="v1.31.4+k3s1"
HELM_VERSION="v3.16.4"
CLOUDFLARED_VERSION="2024.12.2"

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
Uso: $0 --role={sp1|sp2|pa1} [opções]

Roles:
  sp1       Cluster K3s na máquina principal (Ryzen 9950X — Arch Linux)
            simulando o EVEO SP1 (Cotia).
  sp2       Cluster K3s na máquina secundária (Core i7 — Ubuntu Server)
            simulando o EVEO SP2 (Osasco).
  pa1       Cluster K3s + containers Docker isolados na máquina i7
            simulando o DC institucional UNIFESSPA (Marabá). Hospeda Vault
            Transit (auto-unseal cross-cluster), etcd quorum, Keycloak source,
            MinIO replica e backup target.
  witness   ALIAS DEPRECATED de pa1 (emite warning).

Opções:
  --skip-k3s          Pula instalação do K3s
  --skip-docker       Pula instalação do Docker
  --enable-cloudflared Inclui setup do Cloudflare Tunnel (requer login)
  --dry-run           Apenas mostra o que seria feito
  -h, --help          Esta mensagem

Exemplos:
  $0 --role=sp1
  $0 --role=sp2 --enable-cloudflared
  $0 --role=pa1
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
    log_error "Role obrigatório (--role=sp1|sp2|pa1)"
    usage
fi

# Alias DEPRECATED: witness → pa1.
if [[ "$ROLE" == "witness" ]]; then
    log_warn "--role=witness é alias DEPRECATED de --role=pa1. Use --role=pa1."
    ROLE="pa1"
fi

if [[ "$ROLE" != "sp1" && "$ROLE" != "sp2" && "$ROLE" != "pa1" ]]; then
    log_error "Role inválido: '$ROLE'. Use sp1, sp2 ou pa1."
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
        # Pacote do repositório oficial Ubuntu — evita curl-pipe-sh como root.
        run "sudo apt-get update -qq"
        run "sudo apt-get install -y docker.io docker-compose-v2"
        run "sudo systemctl enable --now docker"
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

    local node_name="uniplus-$ROLE"

    if command -v k3s &> /dev/null; then
        local existing_node_name=""
        if command -v kubectl &> /dev/null; then
            existing_node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        fi
        if [[ -z "$existing_node_name" ]]; then
            existing_node_name=$(sudo k3s kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        fi

        if [[ "$existing_node_name" == "$node_name" ]]; then
            log_success "K3s já instalado para role '$ROLE': $(k3s --version | head -1)"
            return
        fi

        if [[ -n "$existing_node_name" ]]; then
            log_error "K3s já instalado para outro role: node '$existing_node_name' != esperado '$node_name'."
        else
            log_error "K3s já instalado, mas não foi possível identificar o node atual."
        fi
        log_error "Use um host/VM limpo para este role ou remova o cluster K3s existente antes de prosseguir."
        exit 1
    fi

    log_info "Instalando K3s $K3S_VERSION (cluster independente para $ROLE)..."

    local node_ip
    node_ip=$(hostname -I | awk '{print $1}')

    run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
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

    log_info "Instalando Helm $HELM_VERSION..."
    local helm_tar="/tmp/helm-${HELM_VERSION}-linux-amd64.tar.gz"
    local helm_sha="/tmp/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
    run "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz -o $helm_tar"
    run "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum -o $helm_sha"
    # O arquivo sha256sum contém o basename sem path — extrair só o hash e
    # construir a linha com o path completo para sha256sum -c funcionar.
    run "echo \"\$(awk '{print \$1}' $helm_sha)  $helm_tar\" | sha256sum -c"
    run "tar -xzf $helm_tar -C /tmp linux-amd64/helm"
    run "sudo install /tmp/linux-amd64/helm /usr/local/bin/helm"
    run "rm -rf $helm_tar $helm_sha /tmp/linux-amd64"
    log_success "Helm $HELM_VERSION instalado."
}

step_install_argocd() {
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

step_setup_pa1_extras() {
    if [[ "$ROLE" != "pa1" ]]; then
        return
    fi

    log_info "Configurando containers Docker isolados do DC institucional simulado (PA1)..."

    # Bridge dedicada para os componentes que rodam fora do K8s em pa1
    # (etcd quorum, keycloak-master, minio-master, backup-target).
    # CIDR alinhado ao environments/lab-pa1/values.yaml (172.30.0.0/16).
    run "docker network create --subnet 172.30.0.0/16 unifesspa-sim 2>/dev/null || true"

    log_warn "Containers PA1 (etcd, keycloak-master, minio-master, backup-target) ainda não automatizados. Veja docs/SETUP.md seção 9."
    log_info "Próximos passos manuais:"
    echo "  1. cd $REPO_ROOT/data/pa1-extras"
    echo "  2. Criar docker-compose.yml conforme SETUP.md (consensusWitness, keycloakMaster,"
    echo "     minioMaster, backupTarget conforme environments/lab-pa1/values.yaml)"
    echo "  3. docker compose up -d"
}

step_setup_vault_transit_tls() {
    if [[ "$ROLE" != "pa1" ]]; then
        return
    fi

    log_info "Gerando certificado TLS self-signed para Vault Transit (achado #37)..."

    local cert_dir="/tmp/vault-transit-tls-$$"
    run "mkdir -p $cert_dir"
    run "openssl req -x509 -newkey rsa:4096 \
        -keyout $cert_dir/tls.key \
        -out $cert_dir/tls.crt \
        -days 3650 -noenc \
        -subj '/CN=vault-transit.uniplus.lab/O=UniPlus Lab' \
        -addext 'subjectAltName=IP:192.168.0.20,DNS:vault-transit'"

    run "kubectl create namespace vault-transit --dry-run=client -o yaml | kubectl apply -f -"
    run "kubectl create secret tls vault-transit-tls \
        --cert=$cert_dir/tls.crt \
        --key=$cert_dir/tls.key \
        -n vault-transit \
        --dry-run=client -o yaml | kubectl apply -f -"

    run "rm -rf $cert_dir"
    log_success "Secret vault-transit-tls criado em namespace vault-transit."
    log_warn "Cert self-signed válido por 3650 dias. Substituir por cert gerenciado quando cert-manager (#15) estiver pronto."
}

step_setup_cloudflared() {
    if $SKIP_CLOUDFLARED; then
        log_warn "Pulando Cloudflare Tunnel (use --enable-cloudflared para incluir)"
        return
    fi
    
    if command -v cloudflared &> /dev/null; then
        log_success "cloudflared já instalado"
    else
        log_info "Instalando cloudflared $CLOUDFLARED_VERSION..."
        local cf_bin="/tmp/cloudflared-linux-amd64"
        local cf_sha="/tmp/cloudflared-linux-amd64.sha256"
        run "curl -fsSL https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64 -o $cf_bin"
        run "curl -fsSL https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-amd64.sha256 -o $cf_sha"
        # Formato do arquivo: apenas o hash, sem nome de arquivo — usar sha256sum -c
        run "echo \"\$(cat $cf_sha)  $cf_bin\" | sha256sum -c"
        run "sudo install $cf_bin /usr/local/bin/cloudflared"
        run "rm -f $cf_bin $cf_sha"
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
        echo "  5. Para auto-unseal Transit funcionar, criar Secret com token"
        echo "     gerado no bootstrap do Vault Transit em pa1 (RUNBOOKS §1.4):"
        echo "       kubectl -n vault create secret generic vault-transit-token \\"
        echo "         --from-literal=token=<SP_AUTOUNSEAL_TOKEN>"
        echo ""
        echo "  6. Validar instalação:"
        echo "       $REPO_ROOT/scripts/validate-cluster.sh"
    fi

    if [[ "$ROLE" == "pa1" ]]; then
        echo "  1. Verificar K3s:"
        echo "       kubectl get nodes"
        echo ""
        echo "  2. Aplicar manifests do ArgoCD (este cluster):"
        echo "       kubectl apply -f $REPO_ROOT/argocd/project.yaml"
        echo "       kubectl apply -f $REPO_ROOT/argocd/applicationset.yaml"
        echo ""
        echo "  3. Aguardar Vault Transit subir (selado, esperado):"
        echo "       kubectl -n vault-transit get pods"
        echo ""
        echo "  4. Bootstrap do Vault Transit (Shamir 5/3, engine Transit, token):"
        echo "       seguir docs/RUNBOOKS.md §1.4.A"
        echo ""
        echo "  5. Subir containers Docker isolados (etcd, keycloak-master,"
        echo "     minio-master, backup-target) — ver passo manual acima."
        echo ""
        echo "  Nota: cert TLS self-signed do Transit criado em vault-transit/vault-transit-tls."
        echo "        Substituir por cert gerenciado quando cert-manager (#15) estiver pronto."
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
step_setup_pa1_extras
step_setup_vault_transit_tls
step_setup_cloudflared
step_summary
