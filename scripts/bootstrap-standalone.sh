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

# Insere uma regra iptables ANTES do REJECT default do Ubuntu OCI
# (`reject-with icmp-host-prohibited`) no chain especificado. Idempotente
# por reset+reinsert — se a regra já existe (em qualquer posição), é
# removida e reinserida na posição correta. Isso lida com:
#   - Re-runs do bootstrap (regra já presente em pos correta — drop+reinsert noop)
#   - Mudança de ordem do chain entre runs (image atualizada, k3s/docker
#     adicionando regras, hooks que reordenam) — recoloca antes do REJECT
#   - Pacote ainda dropped pq ACCEPT caiu DEPOIS do REJECT — corrige
# Sem o REJECT no chain (host customizado), insere na pos 1 com warning.
#
# Uso: iptables_ensure_before_reject <chain> <-args para a regra>
# Exemplo: iptables_ensure_before_reject FORWARD -s 10.42.0.0/16 -d 10.0.0.0/16 -j ACCEPT
iptables_ensure_before_reject() {
    local chain="$1"
    shift

    if $DRY_RUN; then
        echo "[DRY-RUN] iptables_ensure_before_reject $chain $*"
        return
    fi

    # PASSO 1: Remover toda cópia da regra (em qualquer posição). Loop trata
    # caso de múltiplas cópias acumuladas por re-runs de scripts pré-fix.
    while sudo iptables -C "$chain" "$@" 2>/dev/null; do
        sudo iptables -D "$chain" "$@"
    done

    # PASSO 2: AGORA localizar a linha do REJECT (icmp-host-prohibited) com
    # o chain já limpo da regra. Calcular antes do delete dá posição stale —
    # quando a regra original estava antes do REJECT, deletá-la move o REJECT
    # para frente, e a posição calculada vira fora-do-fim do chain (insert
    # vai pro append, depois do REJECT).
    #
    # `iptables -S` dá output canônico (uma regra por linha, prefixada com
    # `-A`). Numeramos com `nl` e procuramos a primeira linha com REJECT
    # + reject-with. A linha 1 do output é a definição da chain (`-P`/`-N`),
    # então a posição da regra para `iptables -I` é (linha do REJECT - 1).
    local reject_line
    reject_line=$(sudo iptables -S "$chain" 2>/dev/null \
        | nl -ba \
        | awk '/-j REJECT.*reject-with icmp-host-prohibited/ {print $1; exit}')
    [[ -n "$reject_line" ]] && reject_line=$(( reject_line - 1 ))

    # PASSO 3: Inserir antes do REJECT, ou no topo se não houver REJECT.
    if [[ -n "$reject_line" ]] && (( reject_line > 0 )); then
        sudo iptables -I "$chain" "$reject_line" "$@"
        log_success "iptables: regra (re)inserida em $chain pos $reject_line (antes do REJECT)"
    else
        sudo iptables -I "$chain" 1 "$@"
        log_warn "iptables: nenhum REJECT default em $chain — regra inserida no topo (pos 1)"
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
    # Inserir ACCEPT *antes do REJECT* para os dois sentidos. Em standalone,
    # 10.0.0.0/16 = VCN inteira (subnet pública 10.0.1.0/24 do k8s-host +
    # subnet privada 10.0.2.0/24 do data-host). Diagnóstico original em
    # issue #123, tratado em #124.
    #
    # Posição é detectada dinamicamente — re-runs após reordenação de chain
    # (image nova, hooks K3s/docker, regras manuais) reposicionam corretamente.
    iptables_ensure_before_reject FORWARD -s 10.42.0.0/16 -d 10.0.0.0/16 -j ACCEPT
    iptables_ensure_before_reject FORWARD -d 10.42.0.0/16 -s 10.0.0.0/16 -j ACCEPT
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
    # *antes do REJECT*. Defesa em profundidade: Security List OCI já filtra
    # antes do pacote chegar ao host, então abrir TCP/VCN aqui não é wide-open
    # — é só remover o bloqueio "extra" do iptables que duplicava com a SL
    # mas com whitelist por porta diferente. Histórico: descoberto durante
    # bootstrap manual do Postgres em 2026-05-05, codificado por #124.
    #
    # Posição detectada dinamicamente; re-runs após reordenação reposicionam.
    iptables_ensure_before_reject INPUT -s 10.0.0.0/16 -p tcp -j ACCEPT
    install_iptables_persistent
    log_success "iptables INPUT configurado e persistido."
}

# Configura Postgres 18 como container Docker gerenciado por systemd no data-host.
#
# Idempotência (decisões independentes):
#   - .bootstrap-creds: se já existe, preserva senhas. Caso contrário, gera
#     novas (256 bits cada) — exceto se cluster já inicializado sem creds,
#     onde aborta apontando §9.4 do runbook.
#   - 00-keycloak.sql (init SQL): efêmero. Gerado sempre que o cluster ainda
#     não foi inicializado (PG_VERSION ausente em data/), shredded após o
#     primeiro pg_isready OK. Cobre o fluxo §9.4 (restore creds, data dir
#     vazio → SQL recriado) e elimina cópia persistente do keycloak_pw em
#     cleartext em $DATA_BASE/postgres/init/ (Codex P2 round 2).
#   - EnvironmentFile + systemd unit: sempre re-aplicados (cheap, corrige drift).
#   - Serviço já ativo: não reinicia (evita downtime em re-runs).
#
# Pós-condições para o operador (ver runbook §9.2):
#   1. Copiar keycloak_pw de .bootstrap-creds para gestor institucional
#   2. Salvar em secret/standalone/postgres/keycloak no Vault
#   3. shred -u .bootstrap-creds
step_data_setup_postgres() {
    # Honra --skip-docker: se Docker não está disponível e o usuário pediu
    # explicitamente para pular instalação, pulamos também o setup do Postgres
    # (que depende de docker run/exec). Sem este guard, --skip-docker mutaria
    # iptables + LVM e falharia tarde aqui — comportamento inconsistente com
    # a flag documentada (Codex P2 round 4).
    if $SKIP_DOCKER && ! command -v docker &>/dev/null; then
        log_warn "Docker indisponível e --skip-docker ativo — pulando setup do Postgres."
        return
    fi

    log_info "Configurando Postgres 18 systemd..."

    local creds_file="$DATA_BASE/postgres/.bootstrap-creds"
    local init_sql="$DATA_BASE/postgres/init/00-keycloak.sql"
    local env_file="/etc/uniplus-postgres.env"
    local unit_file="/etc/systemd/system/uniplus-postgres.service"

    # Diretórios + ownership: ambos pertencem ao uid 70 (postgres no container
    # postgres:18-alpine — Alpine usa uid 70, NÃO 999 que é a convenção das
    # imagens Debian-based). O entrypoint do postgres:18-alpine roda os scripts
    # de init /docker-entrypoint-initdb.d/*.sql AS the postgres user (uid 70 +
    # gosu drop após chown -R do PGDATA). Com init dir owned 70:70 + mode 700,
    # o uid 70 consegue traverse e ler — chown errado bloqueia silenciosamente
    # o script de init e o role/db `keycloak` nunca é criado (#127 Codex P1 +
    # code review).
    run "sudo mkdir -p $DATA_BASE/postgres/data $DATA_BASE/postgres/init"
    run "sudo chown 70:70 $DATA_BASE/postgres/data $DATA_BASE/postgres/init"
    run "sudo chmod 700 $DATA_BASE/postgres/init"

    # Detectar se o cluster Postgres já foi inicializado pelo entrypoint.
    # PG_VERSION é canônico — escrito por initdb na primeira inicialização e
    # presente em qualquer layout de PGDATA (postgres:18 entrypoint cria sob
    # /var/lib/postgresql/data ou subdir vendor-specific). `find -print -quit`
    # retorna na primeira ocorrência, robusto a variações de layout.
    local cluster_initialized=false
    if ! $DRY_RUN && \
       sudo find "$DATA_BASE/postgres/data" -name PG_VERSION -print -quit 2>/dev/null | grep -q .; then
        cluster_initialized=true
    fi

    # ---- Decisão 1: .bootstrap-creds (preservar / gerar / abortar) ----
    if sudo test -f "$creds_file" 2>/dev/null; then
        log_success "Bootstrap creds já existentes — preservando senhas."
    elif $DRY_RUN; then
        log_warn "Dry-run: senhas iniciais seriam geradas em $creds_file"
    elif $cluster_initialized; then
        # Guard: cluster inicializado mas sem .bootstrap-creds. Acontece quando
        # operador rodou `shred -u` (runbook §9.2) e re-executa o bootstrap.
        # Regenerar agora produziria mismatch — novo super_pw no EnvironmentFile
        # vs senha antiga persistida no cluster. Persistir o keycloak_pw novo
        # no Vault quebraria ESO/Keycloak com auth error.
        log_error "$creds_file ausente, mas cluster Postgres já existe em $DATA_BASE/postgres/data"
        log_error "Regenerar senhas agora produziria mismatch entre EnvironmentFile e cluster."
        log_error "Restaure $creds_file a partir do Vault — ver docs/RUNBOOKS.md §9.4."
        exit 1
    else
        log_info "Gerando senhas iniciais (256 bits cada)..."
        local super_pw keycloak_pw
        super_pw=$(openssl rand -hex 32)
        keycloak_pw=$(openssl rand -hex 32)

        # .bootstrap-creds: rastro para operador exportar senhas para gestor
        # institucional + Vault. Após custódia, deve ser removido com `shred -u`
        # (procedimento documentado em docs/RUNBOOKS.md §9.2).
        sudo tee "$creds_file" >/dev/null <<EOF
super_pw=$super_pw
keycloak_pw=$keycloak_pw
EOF
        sudo chown root:root "$creds_file"
        sudo chmod 600 "$creds_file"
        log_warn "Senhas geradas em $creds_file. Custódia obrigatória — ver runbook §9.2."
    fi

    # ---- Decisão 2: 00-keycloak.sql (efêmero — só existe pré-init do cluster) ----
    # Gerado SEMPRE que cluster não está inicializado e .bootstrap-creds existe
    # (cobre fluxo §9.4: restore creds, data dir vazio → SQL re-criado a partir
    # da senha persistida no Vault). Após primeiro pg_isready OK, é shredded
    # mais abaixo nesta função — keycloak_pw em cleartext NÃO persiste em
    # $DATA_BASE/postgres/init/ entre runs (Codex P2 round 2: backups/snapshots
    # do data-host não capturam cópia extra do secret).
    if $DRY_RUN; then
        if ! $cluster_initialized; then
            log_warn "Dry-run: init SQL seria (re)gerado em $init_sql"
        fi
    elif $cluster_initialized; then
        # Cleanup defensivo: se SQL leftover de run anterior persiste após
        # cluster já estar inicializado (ex.: falha entre tee e pg_isready
        # antes do shred), remover agora — não tem mais função e seria leak.
        if sudo test -f "$init_sql" 2>/dev/null; then
            log_warn "Cluster já inicializado mas $init_sql ainda existe — shredding."
            run "sudo shred -u $init_sql"
        fi
    elif sudo test -f "$creds_file" 2>/dev/null; then
        local kc_pw
        kc_pw=$(sudo grep '^keycloak_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$kc_pw" ]]; then
            log_error "keycloak_pw vazio em $creds_file — não consigo (re)gerar init SQL."
            exit 1
        fi
        # Heredoc unquoted permite expansão de $kc_pw. Senha hex-only (openssl
        # rand -hex 32), sem metacaracteres SQL — segura em single-quoted string.
        sudo tee "$init_sql" >/dev/null <<EOF
CREATE ROLE keycloak WITH LOGIN PASSWORD '$kc_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE keycloak OWNER keycloak ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE keycloak TO keycloak;
EOF
        sudo chown 70:70 "$init_sql"
        sudo chmod 600 "$init_sql"
        log_info "Init SQL pronto em $init_sql (será shredded após pg_isready OK)."
    fi

    # EnvironmentFile: sempre re-aplicado (super_pw lido do creds file). Usar
    # `docker run -e POSTGRES_PASSWORD` (sem `=value`) evita exposure da senha
    # em /proc/<pid>/cmdline — docker puxa do env do systemd, populado via
    # EnvironmentFile.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $env_file (POSTGRES_PASSWORD lido de $creds_file)"
    else
        local super_pw_current
        super_pw_current=$(sudo grep '^super_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$super_pw_current" ]]; then
            log_error "Não consegui ler super_pw de $creds_file. Abortando."
            exit 1
        fi
        sudo tee "$env_file" >/dev/null <<EOF
POSTGRES_PASSWORD=$super_pw_current
POSTGRES_INITDB_ARGS=--encoding=UTF8
EOF
        sudo chown root:root "$env_file"
        sudo chmod 600 "$env_file"
    fi

    # systemd unit: sempre re-aplicado. Heredoc single-quoted preserva o
    # conteúdo literal — paths são hardcoded para alinhar com $DATA_BASE
    # (/var/lib/uniplus). A unit em si não usa variáveis de shell; o systemd
    # injeta POSTGRES_PASSWORD via EnvironmentFile no env do docker run.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $unit_file"
    else
        sudo tee "$unit_file" >/dev/null <<'UNIT'
[Unit]
Description=Uni+ Postgres 18 (standalone data-host)
Documentation=https://github.com/unifesspa-edu-br/uniplus-infra/blob/main/docs/RUNBOOKS.md
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=120
EnvironmentFile=/etc/uniplus-postgres.env

ExecStartPre=-/usr/bin/docker rm -f uniplus-postgres
ExecStart=/usr/bin/docker run --rm --name uniplus-postgres \
  --network host \
  -e POSTGRES_PASSWORD \
  -e POSTGRES_INITDB_ARGS \
  -v /var/lib/uniplus/postgres/data:/var/lib/postgresql \
  -v /var/lib/uniplus/postgres/init:/docker-entrypoint-initdb.d:ro \
  postgres:18-alpine \
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
        # Cleanup ainda assim — caso o init SQL tenha sido recriado neste run
        # (fluxo §9.4 com cluster já existente é tratado no guard, mas se o
        # serviço estava ativo em run anterior e o SQL persiste, shred agora).
        if sudo test -f "$init_sql" 2>/dev/null; then
            sudo shred -u "$init_sql"
            log_success "Init SQL leftover shredded."
        fi
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

        # Init SQL cumpriu sua função (entrypoint do postgres:18-alpine
        # executou os scripts em /docker-entrypoint-initdb.d antes de aceitar
        # conexões). Shred elimina cópia persistente do keycloak_pw em
        # cleartext — secret continua vivo apenas em .bootstrap-creds (até o
        # operador custodiar e shred-ar) e no Vault standalone.
        if sudo test -f "$init_sql" 2>/dev/null; then
            sudo shred -u "$init_sql"
            log_success "Init SQL shredded (keycloak_pw não persiste em $DATA_BASE/postgres/init)."
        fi
    fi
}

# Configura Redis 8.6.3 como container Docker gerenciado por systemd no data-host.
#
# UID/GID do container: 999:1000 (redis:8.6.3-alpine — confirmado por
# `docker run --rm redis:8.6.3-alpine id redis`). Diferente do Postgres alpine
# (uid 70), e diferente da convenção 999:999 das imagens Debian-based.
#
# Auth: ACL file (`user default on >password ~* &* +@all`) montado read-only
# em `/usr/local/etc/redis/users.acl`. Senha 256 bits (openssl rand -hex 32),
# custodiada via .bootstrap-creds + Vault (mesmo padrão Postgres §9.2).
#
# Idempotência (decisões independentes):
#   - .bootstrap-creds: preserva se existe, gera se ausente, aborta se ACL file
#     já existe sem .bootstrap-creds (regenerar produziria mismatch entre ACL
#     file e Vault).
#   - ACL file + redis.conf: sempre re-aplicados (redis-server lê em startup).
#   - systemd unit: sempre re-aplicado (cheap, corrige drift).
#   - Serviço já ativo: não reinicia (evita downtime em re-runs).
#
# Persistência híbrida AOF (appendfsync everysec) + RDB snapshots — pattern
# recomendado em 8.x para balance latência/durabilidade.
step_data_setup_redis() {
    # Honra --skip-docker (mesmo guard de step_data_setup_postgres). Sem este,
    # --skip-docker mutaria diretórios e EnvironmentFile e falharia tarde aqui.
    if $SKIP_DOCKER && ! command -v docker &>/dev/null; then
        log_warn "Docker indisponível e --skip-docker ativo — pulando setup do Redis."
        return
    fi

    log_info "Configurando Redis 8.6.3 systemd..."

    local creds_file="$DATA_BASE/redis/.bootstrap-creds"
    local conf_dir="/etc/uniplus-redis"
    local redis_conf="$conf_dir/redis.conf"
    local acl_file="$conf_dir/users.acl"
    local unit_file="/etc/systemd/system/uniplus-redis.service"

    # Diretórios + ownership:
    #   - $DATA_BASE/redis/data: 999:1000 mode 750 (data dir do container,
    #     contém AOF + RDB). O entrypoint do redis:8-alpine roda como root
    #     inicialmente, faz fix_data_dir_perms (chown redis + chmod u+rw nos
    #     RDB/appendonlydir), e dropa privs para uid 999 via setpriv. Pré-set
    #     999:1000 evita warnings do entrypoint.
    #   - /etc/uniplus-redis/: 755 root:root (config dir no host). Precisa ser
    #     traversável pelo uid 999 para que o redis-server (após drop de privs
    #     via setpriv no entrypoint) consiga abrir os arquivos mounted em
    #     /usr/local/etc/redis/. Mode 700 root:root bloqueia traverse e quebra
    #     o startup (Codex P1 round 1). A confidencialidade vem do mode dos
    #     próprios arquivos: redis.conf 644 root:root (sem segredos, legível
    #     para auditoria) e users.acl 600 chown 999:1000 (cleartext da senha
    #     legível apenas pelo redis-server). Mounted read-only no container,
    #     então ACL SAVE / CONFIG REWRITE NÃO funcionam (acl_file é regenerado
    #     pelo bootstrap a partir do .bootstrap-creds — fonte da verdade).
    run "sudo mkdir -p $DATA_BASE/redis/data $conf_dir"
    run "sudo chown 999:1000 $DATA_BASE/redis/data"
    run "sudo chmod 750 $DATA_BASE/redis/data"
    run "sudo chown root:root $conf_dir"
    run "sudo chmod 755 $conf_dir"

    # Detectar inicialização prévia: presença do ACL file no host indica que
    # um run anterior gerou credenciais. AOF/RDB no data dir são proxy mais
    # fraco — em um restore com data dir vazio + ACL file ainda presente, o
    # ACL é o que define a senha aceita pelo Redis em startup.
    local already_initialized=false
    if ! $DRY_RUN && sudo test -f "$acl_file" 2>/dev/null; then
        already_initialized=true
    fi

    # ---- Decisão 1: .bootstrap-creds (preservar / gerar / abortar) ----
    if sudo test -f "$creds_file" 2>/dev/null; then
        log_success "Bootstrap creds Redis já existentes — preservando senha."
    elif $DRY_RUN; then
        log_warn "Dry-run: senha Redis seria gerada em $creds_file"
    elif $already_initialized; then
        # Guard: ACL file existe mas .bootstrap-creds foi shredded sem custódia.
        # Regenerar agora produziria senha nova no Vault diferente da senha
        # ativa no ACL file — apps consumidoras (Fase 5) leriam Vault e
        # falhariam autenticando.
        log_error "$creds_file ausente, mas $acl_file já existe."
        log_error "Regenerar senha agora produziria mismatch entre ACL file e Vault."
        log_error "Restaure $creds_file a partir do Vault — ver docs/RUNBOOKS.md §11.4."
        exit 1
    else
        log_info "Gerando senha Redis (256 bits)..."
        local default_pw
        default_pw=$(openssl rand -hex 32)
        sudo tee "$creds_file" >/dev/null <<EOF
default_pw=$default_pw
EOF
        sudo chown root:root "$creds_file"
        sudo chmod 600 "$creds_file"
        log_warn "Senha gerada em $creds_file. Custódia obrigatória — ver runbook §11.2."
    fi

    # ---- Decisão 2: ACL file (sempre regerado a partir da senha custodiada) ----
    # Diferente do Postgres init SQL (efêmero, shredded após primeira inicialização),
    # o ACL file PERSISTE — redis-server lê em todo startup e reload. Não há
    # rastro extra: a senha vive em .bootstrap-creds (até custódia + shred) e no
    # ACL file (cifrada como hash SHA256 internamente, mas o file contém o
    # cleartext até o redis re-escrever em ACL SAVE — que aqui é noop por mount
    # read-only). Trade-off aceito: ACL file é root:root 600 no filesystem
    # do host; visibilidade limitada a quem tem sudo no data-host.
    if $DRY_RUN; then
        log_warn "Dry-run: ACL file seria escrito em $acl_file"
    elif sudo test -f "$creds_file" 2>/dev/null; then
        local pw
        pw=$(sudo grep '^default_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$pw" ]]; then
            log_error "default_pw vazio em $creds_file — não posso (re)gerar ACL file."
            exit 1
        fi
        # Heredoc unquoted permite expansão de $pw. Senha hex-only (openssl
        # rand -hex 32), sem metacaracteres ACL — segura na linha do user.
        sudo tee "$acl_file" >/dev/null <<EOF
user default on >$pw ~* &* +@all
EOF
        sudo chown 999:1000 "$acl_file"
        sudo chmod 600 "$acl_file"
        unset pw
    fi

    # redis.conf (sempre re-aplicado). Heredoc single-quoted preserva conteúdo
    # literal — paths são hardcoded para alinhar com $DATA_BASE/$conf_dir.
    # Permissão 644 root:root: o conf NÃO contém segredos (a senha vive no
    # users.acl). Manter o conf legível pelo grupo geral simplifica auditoria
    # operacional sem leak. Diverge intencionalmente do users.acl, que continua
    # 600 chown 999:1000 — defesa em camadas (owner restrito + mode restrito)
    # apropriada quando o arquivo carrega cleartext da senha.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $redis_conf"
    else
        sudo tee "$redis_conf" >/dev/null <<'CONF'
# Listeners — bind explícito (protected-mode default `yes` em 7+ exige
# bind + auth; sem bind o redis recusa conexões não-loopback)
bind 10.0.2.87 127.0.0.1 -::1
port 6379
protected-mode yes

# Auth via ACL file (mounted read-only no container)
aclfile /usr/local/etc/redis/users.acl

# Persistência híbrida AOF + RDB
appendonly yes
appendfsync everysec
appendfilename "appendonly.aof"
# RDB snapshots: dump se ≥ 1 chave em 1h, ≥ 100 em 5min, ≥ 10000 em 1min
save 3600 1 300 100 60 10000

# Memory cap — data-host tem 16GB; deixa margem para Postgres + futuros services
maxmemory 2gb
maxmemory-policy allkeys-lru

# Data dir (mount /data dentro do container)
dir /data

# Logging para stdout (capturado por journalctl via systemd)
logfile ""
loglevel notice
CONF
        sudo chown root:root "$redis_conf"
        sudo chmod 644 "$redis_conf"
    fi

    # systemd unit (sempre re-aplicado). Heredoc single-quoted: paths hardcoded.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $unit_file"
    else
        sudo tee "$unit_file" >/dev/null <<'UNIT'
[Unit]
Description=Uni+ Redis 8.6.3 (standalone data-host)
Documentation=https://github.com/unifesspa-edu-br/uniplus-infra/blob/main/docs/RUNBOOKS.md
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=120

ExecStartPre=-/usr/bin/docker rm -f uniplus-redis
ExecStart=/usr/bin/docker run --rm --name uniplus-redis \
  --network host \
  -v /var/lib/uniplus/redis/data:/data \
  -v /etc/uniplus-redis:/usr/local/etc/redis:ro \
  redis:8.6.3-alpine \
  redis-server /usr/local/etc/redis/redis.conf

ExecStop=/usr/bin/docker stop -t 30 uniplus-redis

[Install]
WantedBy=multi-user.target
UNIT
    fi

    run "sudo systemctl daemon-reload"
    run "sudo systemctl enable uniplus-redis"

    if $DRY_RUN; then
        echo "[DRY-RUN] systemctl start uniplus-redis + smoke test PING/PONG"
    elif sudo systemctl is-active --quiet uniplus-redis; then
        log_success "uniplus-redis já ativo — preservando state (sem restart)."
    else
        sudo systemctl start uniplus-redis
        log_info "Aguardando Redis aceitar conexões..."
        local pw
        pw=$(sudo grep '^default_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$pw" ]]; then
            log_error "default_pw vazio em $creds_file — não consigo validar PING."
            exit 1
        fi
        # Senha via stdin (`<<<` + `read -r` no shell do container) — NÃO em
        # argv. `docker exec -i` conecta stdin local ao stdin do processo
        # remoto; REDISCLI_AUTH é env var do redis-cli (forma oficial de
        # passar senha sem cmdline exposure). Mesmo padrão de §9.3 do runbook.
        local attempts=0
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
    echo "Data services systemd:"
    echo "  systemctl status uniplus-postgres"
    echo "  systemctl status uniplus-redis"
    echo ""
    echo "Custódia das senhas iniciais (PRIMEIRA EXECUÇÃO):"
    echo "  Postgres — runbook §9.2:"
    echo "    1. Ler:        sudo cat $DATA_BASE/postgres/.bootstrap-creds"
    echo "    2. Custodiar:  Vault (secret/standalone/postgres/keycloak) + gestor institucional"
    echo "    3. Limpar:     sudo shred -u $DATA_BASE/postgres/.bootstrap-creds"
    echo "  Redis — runbook §11.2:"
    echo "    1. Ler:        sudo cat $DATA_BASE/redis/.bootstrap-creds"
    echo "    2. Custodiar:  Vault (secret/standalone/redis/default) + gestor institucional"
    echo "    3. Limpar:     sudo shred -u $DATA_BASE/redis/.bootstrap-creds"
    echo ""
    echo "Próximos passos (Epic data/*):"
    echo "  Os serviços Kafka e MinIO serão provisionados em sub-tasks futuras"
    echo "  (mesmo padrão de Postgres/Redis: container Docker via systemd nos mounts dedicados)."
    echo ""
    echo "Validar:"
    echo "  df -h $DATA_BASE/*"
    echo "  sudo vgs && sudo lvs"
    echo "  sudo docker exec uniplus-postgres pg_isready -U postgres"
    echo "  sudo docker exec -i uniplus-redis sh -c 'read -r P; REDISCLI_AUTH=\$P redis-cli ping' \\"
    echo "    <<<\"\$(sudo grep ^default_pw= $DATA_BASE/redis/.bootstrap-creds | cut -d= -f2)\""
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
        step_data_setup_postgres
        step_data_setup_redis
        summary_data
        ;;
esac
