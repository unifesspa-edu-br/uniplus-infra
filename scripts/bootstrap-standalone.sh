#!/usr/bin/env bash
# ============================================================================
# bootstrap-standalone.sh
#
# Provisiona o ambiente standalone Uni+ em dois hosts OCI separados.
#
# Uso:
#   ./bootstrap-standalone.sh --role=standalone-k8s   # k8s-host: K3s + Helm + ArgoCD
#   ./bootstrap-standalone.sh --role=standalone-data   # data-host: Docker + LVM + mounts
#
# Roles originais (sp1/sp2/pa1) continuam no bootstrap-lab.sh.
# Este script é exclusivo para o ambiente standalone OCI (Ubuntu 24.04 LTS).
#
# Pré-requisitos:
#   - Ubuntu 24.04 LTS
#   - Não executar como root (usa sudo internamente)
#   - standalone-data: 4 block volumes OCI anexados (postgres 200GB, kafka 100GB,
#                      minio 200GB, vault 50GB) — rodar lsblk antes para confirmar
# ============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ============== Versões pinadas ==============
K3S_VERSION="v1.31.4+k3s1"
HELM_VERSION="v3.16.4"
ARGOCD_VERSION="v2.14.3"

# ============== Defaults ==============
ROLE=""
DRY_RUN=false
SKIP_K3S=false
SKIP_DOCKER=false

# TLS SANs para o k8s-host — ajustar se o IP ou domínio mudar
K8S_PUBLIC_IP="164.152.53.29"
K8S_DOMAIN="standalone.portaluni.com.br"

# Mount base para os volumes de dados
DATA_BASE="/var/lib/uniplus"

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

usage() {
    cat <<EOF
Uso: $0 --role={standalone-k8s|standalone-data} [opções]

Roles:
  standalone-k8s   Instala K3s + Helm + ArgoCD no k8s-host (subnet pública OCI).
  standalone-data  Instala Docker, configura LVM nos block volumes e cria mount
                   points em $DATA_BASE/{postgres,kafka,minio,vault} no data-host
                   (subnet privada OCI).

Opções:
  --skip-k3s      (standalone-k8s) Pula instalação do K3s
  --skip-docker   (standalone-data) Pula instalação do Docker
  --dry-run       Apenas mostra o que seria feito, sem executar
  -h, --help      Esta mensagem

Exemplos:
  $0 --role=standalone-k8s --dry-run
  $0 --role=standalone-k8s
  $0 --role=standalone-data --dry-run
  $0 --role=standalone-data
EOF
    exit 0
}

# ============== Parse args ==============
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role=*)        ROLE="${1#*=}"; shift ;;
        --dry-run)       DRY_RUN=true; shift ;;
        --skip-k3s)      SKIP_K3S=true; shift ;;
        --skip-docker)   SKIP_DOCKER=true; shift ;;
        -h|--help)       usage ;;
        *) log_error "Opção inválida: $1"; usage ;;
    esac
done

if [[ -z "$ROLE" ]]; then
    log_error "Role obrigatório. Use --role=standalone-k8s ou --role=standalone-data"
    usage
fi

if [[ "$ROLE" != "standalone-k8s" && "$ROLE" != "standalone-data" ]]; then
    log_error "Role inválido: '$ROLE'. Use standalone-k8s ou standalone-data."
    usage
fi

# ============== Helpers ==============
run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        bash -c "$*"
    fi
}

check_ubuntu() {
    if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
        log_error "Este script requer Ubuntu. Sistema detectado: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
        exit 1
    fi
}

check_not_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "Não execute como root. O script usa sudo internamente."
        exit 1
    fi
}

# Instala iptables-persistent (não-interativo) e persiste o ruleset corrente.
# Idempotente — pacote `apt-get install` é noop se já instalado.
install_iptables_persistent() {
    if dpkg -s iptables-persistent &>/dev/null; then
        log_success "iptables-persistent já instalado."
    else
        log_info "Instalando iptables-persistent..."
        # debconf-set-selections suprime o prompt interativo "save current rules?"
        run "echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections"
        run "echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections"
        run "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent"
    fi
    run "sudo netfilter-persistent save"
}

# Insere uma regra iptables apenas se ainda não existe (idempotente).
# Uso: iptables_ensure <chain> <position> <-args para a regra>
# Exemplo: iptables_ensure FORWARD 7 -s 10.42.0.0/16 -d 10.0.0.0/16 -j ACCEPT
iptables_ensure() {
    local chain="$1" pos="$2"
    shift 2
    if $DRY_RUN; then
        echo "[DRY-RUN] iptables -C $chain $* 2>/dev/null || iptables -I $chain $pos $*"
    elif sudo iptables -C "$chain" "$@" 2>/dev/null; then
        log_success "iptables: regra já presente em $chain ($*)"
    else
        sudo iptables -I "$chain" "$pos" "$@"
        log_success "iptables: regra inserida em $chain pos $pos ($*)"
    fi
}

# ============================================================================
# ROLE: standalone-k8s
# ============================================================================

step_k8s_check_prerequisites() {
    log_info "Verificando pré-requisitos (standalone-k8s)..."
    check_ubuntu
    check_not_root

    for cmd in curl git; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Comando '$cmd' não encontrado."
            exit 1
        fi
    done

    log_success "Pré-requisitos OK."
}

step_install_k3s() {
    if $SKIP_K3S; then
        log_warn "Pulando instalação do K3s (--skip-k3s)"
        # Kubeconfig ainda é necessário para step_install_argocd
        if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
            run "mkdir -p $HOME/.kube"
            run "sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config"
            run "sudo chown $(id -u):$(id -g) $HOME/.kube/config"
            log_success "Kubeconfig copiado."
        else
            log_warn "K3s não instalado — kubeconfig indisponível. step_install_argocd pode falhar."
        fi
        return
    fi

    local node_name="uniplus-standalone"

    if command -v k3s &>/dev/null; then
        # API pode demorar alguns segundos após boot — retry com backoff; skip em dry-run
        local existing attempts=0
        if $DRY_RUN; then
            log_warn "Dry-run: pulando probe da API K3s."
            existing="$node_name"
        else
            until existing=$(sudo k3s kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null) && [[ -n "$existing" ]]; do
                attempts=$(( attempts + 1 ))
                if [[ "$attempts" -ge 6 ]]; then
                    log_error "API K3s não respondeu após 30s. Verifique: sudo systemctl status k3s"
                    exit 1
                fi
                log_warn "API K3s ainda inicializando, aguardando 5s... ($attempts/6)"
                sleep 5
            done
        fi
        if [[ "$existing" == "$node_name" ]]; then
            log_success "K3s já instalado: $(k3s --version | head -1)"
        else
            log_error "K3s instalado com node '$existing' (esperado '$node_name'). Use host limpo ou remova o cluster."
            exit 1
        fi
    else
        local node_ip
        node_ip=$(hostname -I | awk '{print $1}')

        log_info "Instalando K3s $K3S_VERSION (node: $node_name, IP: $node_ip)..."

        # --disable traefik: o chart platform/traefik/ instala o IngressController
        # do projeto (v3.6.15 com middlewares Uni+ e IngressClass `traefik`).
        # Sem --disable, o Traefik bundled do K3s competiria pelo bind 80/443
        # e pela IngressClass de mesmo nome.
        # --disable servicelb: usamos NodePort+hostPort em standalone (single
        # host com IP público) — ServiceLB do K3s não acrescenta nada aqui.
        run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
            --node-name $node_name \
            --cluster-init \
            --tls-san $node_name \
            --tls-san $node_ip \
            --tls-san $K8S_PUBLIC_IP \
            --tls-san $K8S_DOMAIN \
            --disable servicelb \
            --disable traefik \
            --write-kubeconfig-mode 644"
    fi

    run "mkdir -p $HOME/.kube"
    run "sudo cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config"
    run "sudo chown $(id -u):$(id -g) $HOME/.kube/config"

    log_success "K3s instalado."
}

step_install_helm() {
    if command -v helm &>/dev/null; then
        log_success "Helm já instalado: $(helm version --short)"
        return
    fi

    log_info "Instalando Helm $HELM_VERSION..."
    local helm_tar="/tmp/helm-${HELM_VERSION}-linux-amd64.tar.gz"
    local helm_sha="/tmp/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum"
    run "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz -o $helm_tar"
    run "curl -fsSL https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum -o $helm_sha"
    run "echo \"\$(awk '{print \$1}' $helm_sha)  $helm_tar\" | sha256sum -c"
    run "tar -xzf $helm_tar -C /tmp linux-amd64/helm"
    run "sudo install /tmp/linux-amd64/helm /usr/local/bin/helm"
    run "rm -rf $helm_tar $helm_sha /tmp/linux-amd64"
    log_success "Helm $HELM_VERSION instalado."
}

step_install_argocd() {
    log_info "Instalando ArgoCD..."

    run "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -"
    # --server-side evita o limite de 262144 bytes nas anotações dos CRDs do ArgoCD no K3s
    # --force-conflicts resolve conflitos de field manager (necessário em re-runs após falha client-side)
    run "kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"

    log_info "Aguardando ArgoCD ficar disponível (até 5 min)..."
    run "kubectl wait --for=condition=available --timeout=300s \
        deployment/argocd-server \
        deployment/argocd-repo-server \
        deployment/argocd-applicationset-controller \
        -n argocd"

    log_info "Senha inicial do admin ArgoCD:"
    run "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo"

    log_success "ArgoCD instalado."
}

step_k8s_configure_iptables() {
    log_info "Configurando iptables (FORWARD chain) para tráfego pod K8s → VCN..."
    # Default do Ubuntu OCI (instalado por iptables-persistent durante boot
    # via cloud-init): regra `REJECT --reject-with icmp-host-prohibited` no
    # chain FORWARD, posicionada ANTES da chain `FLANNEL-FWD`. Resultado:
    # pacotes saindo de pods K8s (source 10.42.0.0/16, flannel pod CIDR) com
    # destino na VCN OCI (10.0.0.0/16, ex.: data-host em 10.0.2.x) batem no
    # REJECT antes de chegar nas regras de masquerade do flannel — Pod fica
    # com `Host is unreachable`, mesmo com Security List OCI permitindo.
    #
    # Inserir ACCEPT em pos 7 (antes do REJECT) para os dois sentidos. Em
    # standalone, 10.0.0.0/16 = VCN inteira (subnet pública 10.0.1.0/24
    # do k8s-host + subnet privada 10.0.2.0/24 do data-host). Diagnóstico
    # original em issue #123, tratado em #124.
    iptables_ensure FORWARD 7 -s 10.42.0.0/16 -d 10.0.0.0/16 -j ACCEPT
    iptables_ensure FORWARD 7 -d 10.42.0.0/16 -s 10.0.0.0/16 -j ACCEPT
    install_iptables_persistent
    log_success "iptables FORWARD configurado e persistido."
}

summary_k8s() {
    echo ""
    echo "============================================"
    log_success "Bootstrap standalone-k8s concluído"
    echo "============================================"
    echo ""
    echo "Próximos passos:"
    echo "  1. Verificar cluster:"
    echo "       kubectl get nodes"
    echo ""
    echo "  2. Registrar cluster no ArgoCD:"
    echo "       argocd cluster add <context> --label uniplus.io/managed=true --label environment=standalone"
    echo ""
    echo "  3. Aplicar manifests GitOps:"
    echo "       kubectl apply -f $REPO_ROOT/argocd/project.yaml"
    echo "       kubectl apply -f $REPO_ROOT/argocd/applicationset.yaml"
    echo ""
    echo "  4. Acessar ArgoCD:"
    echo "       kubectl port-forward -n argocd svc/argocd-server 8080:443"
    echo "       https://localhost:8080  (admin / senha mostrada acima)"
    echo ""
    echo "  5. Validar:"
    echo "       $REPO_ROOT/scripts/validate-standalone.sh"
}

# ============================================================================
# ROLE: standalone-data
# ============================================================================

step_data_check_prerequisites() {
    log_info "Verificando pré-requisitos (standalone-data)..."
    check_ubuntu
    check_not_root

    for cmd in curl lsblk; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "Comando '$cmd' não encontrado."
            exit 1
        fi
    done

    # Verifica discos de dados: raw (pré-provisionamento) ou LVM2_member (já inicializados).
    # Aceitar ambos os estados garante idempotência após o primeiro run.
    # Deriva o disco de boot dinamicamente para não depender do nome fixo "sda"
    # (em hosts com vda/nvme0n1 o hardcode destruiria o disco raiz).
    local root_source root_disk
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    root_disk=$(lsblk -no pkname "$root_source" 2>/dev/null || true)
    [[ -z "$root_disk" ]] && root_disk="sda"

    local disk_count
    disk_count=$(lsblk -b -d -o NAME,TYPE,FSTYPE | awk -v boot="$root_disk" '$2=="disk" && ($3=="" || $3=="LVM2_member") && $1!=boot && $1!~/^loop/' | wc -l)

    if [[ "$disk_count" -lt 4 ]]; then
        log_warn "Encontrado $disk_count disco(s) de dados (esperado 4)."
        log_warn "Verifique se os block volumes OCI estão anexados: lsblk -o NAME,SIZE,FSTYPE"
        if ! $DRY_RUN; then
            log_error "Pré-requisito não atendido. Corrija antes de continuar."
            exit 1
        fi
    fi

    log_success "Pré-requisitos OK ($disk_count disco(s) de dados detectados)."
}

step_install_docker() {
    if $SKIP_DOCKER; then
        log_warn "Pulando Docker (--skip-docker)"
        return
    fi

    if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
        log_success "Docker já instalado: $(docker --version)"
        log_success "Docker Compose já instalado: $(docker compose version --short 2>/dev/null || true)"
        return
    fi

    log_info "Instalando Docker + Compose v2..."
    run "sudo apt-get update -qq"
    run "sudo apt-get install -y docker.io docker-compose-v2"
    run "sudo systemctl enable --now docker"
    run "sudo usermod -aG docker $USER"
    log_warn "Logout/login necessário para aplicar o grupo 'docker'."
    log_success "Docker instalado."
}

# Descoberta de discos raw por tamanho (em bytes)
# OCI paravirtualized: sda=boot, sdb/sdc/sdd/sde=block volumes
# Tamanhos esperados: postgres=200GB, kafka=100GB, minio=200GB, vault=50GB
# Para os dois discos de 200GB, usa ordem alfabética: primeiro=postgres, segundo=minio
discover_disks() {
    log_info "Descobrindo mapeamento de discos..."

    local root_source root_disk
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    root_disk=$(lsblk -no pkname "$root_source" 2>/dev/null || true)
    [[ -z "$root_disk" ]] && root_disk="sda"

    mapfile -t raw_disks < <(
        lsblk -b -d -o NAME,SIZE,FSTYPE |
        awk -v boot="$root_disk" '$1!="NAME" && $1!~/^loop/ && $1!=boot && ($3=="" || $3=="LVM2_member")' |
        sort -k1
    )

    if [[ ${#raw_disks[@]} -eq 0 ]]; then
        log_error "Nenhum disco de dados encontrado. Verifique os attachments OCI."
        exit 1
    fi

    echo ""
    log_info "Discos de dados detectados:"
    printf "  %-8s %-12s %s\n" "DEVICE" "TAMANHO" "PROPÓSITO"

    DISK_POSTGRES=""
    DISK_KAFKA=""
    DISK_MINIO=""
    DISK_VAULT=""
    local count_50=0 count_100=0 count_200=0

    for entry in "${raw_disks[@]}"; do
        local name size_bytes size_gb
        name=$(echo "$entry" | awk '{print $1}')
        size_bytes=$(echo "$entry" | awk '{print $2}')
        size_gb=$(( size_bytes / 1024 / 1024 / 1024 ))

        if [[ "$size_gb" -ge 45 && "$size_gb" -le 55 ]]; then
            count_50=$(( count_50 + 1 ))
            if [[ "$count_50" -eq 1 ]]; then
                DISK_VAULT="/dev/$name"
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "vault"
            else
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "50GB EXTRA — topologia inválida"
            fi
        elif [[ "$size_gb" -ge 95 && "$size_gb" -le 105 ]]; then
            count_100=$(( count_100 + 1 ))
            if [[ "$count_100" -eq 1 ]]; then
                DISK_KAFKA="/dev/$name"
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "kafka"
            else
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "100GB EXTRA — topologia inválida"
            fi
        elif [[ "$size_gb" -ge 190 && "$size_gb" -le 210 ]]; then
            count_200=$(( count_200 + 1 ))
            if [[ "$count_200" -eq 1 ]]; then
                DISK_POSTGRES="/dev/$name"
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "postgres (1º de 200GB)"
            elif [[ "$count_200" -eq 2 ]]; then
                DISK_MINIO="/dev/$name"
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "minio (2º de 200GB)"
            else
                printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "200GB EXTRA — topologia inválida"
            fi
        else
            printf "  %-8s %-12s %s\n" "/dev/$name" "${size_gb}GB" "DESCONHECIDO — ignorado"
        fi
    done

    echo ""

    # Validar cardinalidade exata: 1x~50GB, 1x~100GB, 2x~200GB
    local topology_ok=true
    if [[ "$count_50" -ne 1 ]]; then
        log_error "Esperado 1 disco ~50GB (vault), encontrado $count_50. Verifique os attachments OCI."
        topology_ok=false
    fi
    if [[ "$count_100" -ne 1 ]]; then
        log_error "Esperado 1 disco ~100GB (kafka), encontrado $count_100. Verifique os attachments OCI."
        topology_ok=false
    fi
    if [[ "$count_200" -ne 2 ]]; then
        log_error "Esperado 2 discos ~200GB (postgres + minio), encontrado $count_200. Verifique os attachments OCI."
        topology_ok=false
    fi

    if ! $topology_ok; then
        if ! $DRY_RUN; then
            log_error "Topologia de discos inválida. Corrija os attachments antes de continuar."
            exit 1
        fi
        log_warn "Topologia inválida detectada (dry-run — continuando mesmo assim)."
    fi

    log_warn "Confirme o mapeamento acima antes de prosseguir (--dry-run para revisar sem modificar)."
}

setup_lvm_volume() {
    local disk="$1"
    local vg_name="$2"
    local lv_name="$3"
    local mount_point="$4"

    log_info "Configurando LVM: $disk → $vg_name/$lv_name → $mount_point"

    if sudo lvs "$vg_name/$lv_name" &>/dev/null; then
        if sudo blkid "/dev/$vg_name/$lv_name" &>/dev/null; then
            log_success "$vg_name/$lv_name já existe com filesystem. Pulando provisionamento LVM."
        else
            # LV existe mas sem filesystem: lvcreate concluiu, mkfs foi interrompido
            log_warn "$vg_name/$lv_name sem filesystem detectado. Executando mkfs.xfs."
            run "sudo mkfs.xfs /dev/$vg_name/$lv_name"
        fi
    else
        if ! sudo vgs "$vg_name" &>/dev/null; then
            run "sudo pvcreate $disk"
            run "sudo vgcreate $vg_name $disk"
        fi
        run "sudo lvcreate -l 100%FREE -n $lv_name $vg_name"
        run "sudo mkfs.xfs /dev/$vg_name/$lv_name"
    fi

    run "sudo mkdir -p $mount_point"

    if ! mountpoint -q "$mount_point" 2>/dev/null; then
        run "sudo mount /dev/$vg_name/$lv_name $mount_point"
    fi

    if ! grep -qF "/dev/$vg_name/$lv_name" /etc/fstab 2>/dev/null; then
        run "echo '/dev/$vg_name/$lv_name $mount_point xfs defaults,nofail 0 2' | sudo tee -a /etc/fstab"
    fi

    run "sudo chown $USER:$USER $mount_point"

    log_success "$mount_point pronto."
}

step_setup_lvm() {
    if ! command -v lvcreate &>/dev/null || ! command -v mkfs.xfs &>/dev/null; then
        log_info "Instalando LVM2..."
        run "sudo apt-get update -qq"
        run "sudo apt-get install -y lvm2 xfsprogs"
    else
        log_success "LVM2 já instalado. Pulando apt."
    fi

    setup_lvm_volume "$DISK_POSTGRES" "vg-postgres" "lv-postgres" "$DATA_BASE/postgres"
    setup_lvm_volume "$DISK_KAFKA"   "vg-kafka"    "lv-kafka"    "$DATA_BASE/kafka"
    setup_lvm_volume "$DISK_MINIO"   "vg-minio"    "lv-minio"    "$DATA_BASE/minio"
    setup_lvm_volume "$DISK_VAULT"   "vg-vault"    "lv-vault"    "$DATA_BASE/vault"

    log_success "LVM configurado. Volumes montados em $DATA_BASE/."
}

step_create_placeholder_dirs() {
    # postgres/kafka/minio/vault já criados por setup_lvm_volume; apenas redis precisa de mkdir
    log_info "Criando diretório para Redis (disco local, sem block volume dedicado)..."
    run "sudo mkdir -p $DATA_BASE/redis"
    run "sudo chown $USER:$USER $DATA_BASE/redis"
    log_success "$DATA_BASE/redis pronto."
}

step_data_configure_iptables() {
    log_info "Configurando iptables (INPUT chain) para tráfego VCN → data services..."
    # Default do Ubuntu OCI: regra `REJECT --reject-with icmp-host-prohibited`
    # no chain INPUT, com ACCEPT explícito apenas para SSH (TCP 22). Os data
    # services standalone (Postgres 5432, Redis 6379, Kafka 9092, MinIO
    # 9000-9001) ficam inacessíveis externamente, mesmo com a OCI Security
    # List permitindo. Conexão local (127.0.0.1) e SSH continuam OK.
    #
    # Inserir um ACCEPT abrangente para TCP from 10.0.0.0/16 (VCN inteira)
    # antes do REJECT. Defesa em profundidade: Security List OCI já filtra
    # antes do pacote chegar ao host, então abrir TCP/VCN aqui não é wide-open
    # — é só remover o bloqueio "extra" do iptables que duplicava com a SL
    # mas com whitelist por porta diferente. Histórico: descoberto durante
    # bootstrap manual do Postgres em 2026-05-05, codificado por #124.
    iptables_ensure INPUT 5 -s 10.0.0.0/16 -p tcp -j ACCEPT
    install_iptables_persistent
    log_success "iptables INPUT configurado e persistido."
}

summary_data() {
    echo ""
    echo "============================================"
    log_success "Bootstrap standalone-data concluído"
    echo "============================================"
    echo ""
    echo "Volumes montados:"
    echo "  $DATA_BASE/postgres  ← $DISK_POSTGRES (LVM vg-postgres)"
    echo "  $DATA_BASE/kafka     ← $DISK_KAFKA    (LVM vg-kafka)"
    echo "  $DATA_BASE/minio     ← $DISK_MINIO    (LVM vg-minio)"
    echo "  $DATA_BASE/vault     ← $DISK_VAULT    (LVM vg-vault)"
    echo "  $DATA_BASE/redis     (disco local)"
    echo ""
    echo "Próximos passos (Epic data/*):"
    echo "  Os serviços (Postgres, Kafka, MinIO, Vault, Redis) serão provisionados"
    echo "  via docker-compose pelo Epic data/* usando esses mount points."
    echo ""
    echo "Validar:"
    echo "  df -h $DATA_BASE/*"
    echo "  sudo vgs && sudo lvs"
}

# ============================================================================
# Main
# ============================================================================
echo "============================================"
echo "  Uni+ Standalone Bootstrap"
echo "  Role:    $ROLE"
echo "  Dry-run: $DRY_RUN"
echo "============================================"
echo ""

case "$ROLE" in
    standalone-k8s)
        step_k8s_check_prerequisites
        step_install_k3s
        step_k8s_configure_iptables
        step_install_helm
        step_install_argocd
        summary_k8s
        ;;
    standalone-data)
        step_data_check_prerequisites
        step_install_docker
        step_data_configure_iptables
        discover_disks
        step_setup_lvm
        step_create_placeholder_dirs
        summary_data
        ;;
esac
