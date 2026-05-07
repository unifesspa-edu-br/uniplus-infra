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

# Configura MinIO (RELEASE.2025-09-07T16-13-09Z) como container Docker
# gerenciado por systemd no data-host. Single-node single-drive (SNSD) — única
# topologia suportada em standalone single-host. Sem erasure coding (precisa
# ≥4 drives) — zero proteção contra corrupção do drive; backup externo é
# responsabilidade do operador (Story #118 sub-task).
#
# UID/GID do container: 1000:1000 via MINIO_USERNAME/MINIO_GROUPNAME +
# MINIO_UID/MINIO_GID. O entrypoint cria o user dinamicamente em /etc/passwd
# e usa `chroot --userspec` para drop de privs (image roda como root by default).
#
# Auth: MINIO_ROOT_USER (16 bytes hex aleatório, NÃO `admin`/`minioadmin`) +
# MINIO_ROOT_PASSWORD (32 bytes hex). Per-app users criados via mc admin user
# add na Fase 5.
#
# Idempotência (decisões independentes):
#   - .bootstrap-creds: preserva se existe; gera se ausente; aborta se data
#     dir já contém state (.minio.sys/) sem .bootstrap-creds.
#   - EnvironmentFile + systemd unit: sempre re-aplicados (cheap, corrige drift).
#   - Serviço já ativo: não reinicia (evita downtime em re-runs).
#
# AGPL community release (último em 2025-09): security fixes pós-Sep só em
# AIStor enterprise. Aceitável em standalone (validação); decisão arquitetural
# pra prod (alternativas: Garage, SeaweedFS) fica em backlog (Story futura).
step_data_setup_minio() {
    if $SKIP_DOCKER && ! command -v docker &>/dev/null; then
        log_warn "Docker indisponível e --skip-docker ativo — pulando setup do MinIO."
        return
    fi

    log_info "Configurando MinIO 2025-09 systemd..."

    local creds_file="$DATA_BASE/minio/.bootstrap-creds"
    local env_file="/etc/uniplus-minio.env"
    local unit_file="/etc/systemd/system/uniplus-minio.service"

    # Diretórios + ownership: $DATA_BASE/minio/data 1000:1000 mode 750.
    # O entrypoint do MinIO roda como root inicialmente, faz chroot --userspec
    # para uid 1000 antes de invocar `minio server`. Pré-set 1000:1000 evita
    # erros "Permission denied" na primeira escrita do .minio.sys/.
    run "sudo mkdir -p $DATA_BASE/minio/data"
    run "sudo chown 1000:1000 $DATA_BASE/minio/data"
    run "sudo chmod 750 $DATA_BASE/minio/data"

    # Detectar inicialização prévia: presença de .minio.sys/ no data dir
    # indica que MinIO já formatou o drive ao menos uma vez (config + format
    # marker viram persistentes). Análogo a PG_VERSION em Postgres.
    local already_initialized=false
    if ! $DRY_RUN && \
       sudo test -d "$DATA_BASE/minio/data/.minio.sys" 2>/dev/null; then
        already_initialized=true
    fi

    # ---- Decisão 1: .bootstrap-creds (preservar / gerar / abortar) ----
    if sudo test -f "$creds_file" 2>/dev/null; then
        log_success "Bootstrap creds MinIO já existentes — preservando credenciais."
    elif $DRY_RUN; then
        log_warn "Dry-run: credenciais MinIO seriam geradas em $creds_file"
    elif $already_initialized; then
        # Guard: data dir formatado mas .bootstrap-creds shredded sem custódia.
        # Regenerar criaria root_user/root_pw novos no Vault diferentes dos
        # que MinIO aceita em runtime — apps (Fase 5) lendo Vault falhariam.
        log_error "$creds_file ausente, mas $DATA_BASE/minio/data/.minio.sys/ já existe"
        log_error "Regenerar credenciais agora produziria mismatch entre MinIO e Vault."
        log_error "Restaure $creds_file a partir do Vault — ver docs/RUNBOOKS.md §12.4."
        exit 1
    else
        log_info "Gerando credenciais MinIO (root_user 16 bytes hex + root_pw 32 bytes hex)..."
        local root_user root_pw
        root_user=$(openssl rand -hex 16)
        root_pw=$(openssl rand -hex 32)
        sudo tee "$creds_file" >/dev/null <<EOF
root_user=$root_user
root_pw=$root_pw
EOF
        sudo chown root:root "$creds_file"
        sudo chmod 600 "$creds_file"
        log_warn "Credenciais geradas em $creds_file. Custódia obrigatória — ver runbook §12.2."
    fi

    # EnvironmentFile (sempre re-aplicado). Senhas via env do systemd → docker
    # `-e VAR` (sem `=value`); cmdline NÃO expõe (`/proc/<pid>/cmdline` puxa
    # do env de processo, não dos args). MINIO_USERNAME/GROUPNAME/UID/GID
    # instruem o entrypoint a chroot pro user 1000:1000.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $env_file"
    else
        local root_user_current root_pw_current
        root_user_current=$(sudo grep '^root_user=' "$creds_file" | cut -d= -f2)
        root_pw_current=$(sudo grep '^root_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$root_user_current" || -z "$root_pw_current" ]]; then
            log_error "root_user ou root_pw vazio em $creds_file. Abortando."
            exit 1
        fi
        sudo tee "$env_file" >/dev/null <<EOF
MINIO_ROOT_USER=$root_user_current
MINIO_ROOT_PASSWORD=$root_pw_current
MINIO_USERNAME=minio
MINIO_GROUPNAME=minio
MINIO_UID=1000
MINIO_GID=1000
EOF
        sudo chown root:root "$env_file"
        sudo chmod 600 "$env_file"
        unset root_user_current root_pw_current
    fi

    # systemd unit (sempre re-aplicado). Heredoc single-quoted: paths hardcoded.
    # --address e --console-address ligam explicitamente em 10.0.2.87 (subnet
    # privada VCN). Console em 9001 NÃO está exposto externamente (sem
    # IngressRoute) — acesso só via kubectl port-forward ou SSH tunnel.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $unit_file"
    else
        sudo tee "$unit_file" >/dev/null <<'UNIT'
[Unit]
Description=Uni+ MinIO 2025-09 (standalone data-host)
Documentation=https://github.com/unifesspa-edu-br/uniplus-infra/blob/main/docs/RUNBOOKS.md
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=120
EnvironmentFile=/etc/uniplus-minio.env

ExecStartPre=-/usr/bin/docker rm -f uniplus-minio
ExecStart=/usr/bin/docker run --rm --name uniplus-minio \
  --network host \
  -e MINIO_ROOT_USER \
  -e MINIO_ROOT_PASSWORD \
  -e MINIO_USERNAME \
  -e MINIO_GROUPNAME \
  -e MINIO_UID \
  -e MINIO_GID \
  -v /var/lib/uniplus/minio/data:/data \
  quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z \
  server --address 10.0.2.87:9000 --console-address 10.0.2.87:9001 /data

ExecStop=/usr/bin/docker stop -t 30 uniplus-minio

[Install]
WantedBy=multi-user.target
UNIT
    fi

    run "sudo systemctl daemon-reload"
    run "sudo systemctl enable uniplus-minio"

    if $DRY_RUN; then
        echo "[DRY-RUN] systemctl start uniplus-minio + curl /minio/health/live"
    elif sudo systemctl is-active --quiet uniplus-minio; then
        log_success "uniplus-minio já ativo — preservando state (sem restart)."
    else
        sudo systemctl start uniplus-minio
        log_info "Aguardando MinIO aceitar conexões..."
        local attempts=0
        until curl -sf --max-time 2 http://10.0.2.87:9000/minio/health/live >/dev/null 2>&1; do
            attempts=$(( attempts + 1 ))
            if (( attempts >= 18 )); then
                log_error "MinIO não respondeu /minio/health/live em 90s. Ver: sudo journalctl -u uniplus-minio -n 50"
                exit 1
            fi
            sleep 5
        done
        log_success "uniplus-minio ativo + /minio/health/live OK."
    fi
}

# Cria buckets baseline em standalone via mc (one-shot job).
#
# Idempotente — `mc mb --ignore-existing` skip se bucket já existe. Roda em
# container ad-hoc da imagem mc:latest, sem persistência. Buckets são
# pré-cadastros para usos previstos:
#   - keycloak-backups: destino de pg_dump (Story #118 sub-task)
#   - loki-chunks: chunks de log (quando observability aterrissar)
#   - tempo-traces: traces (idem)
#   - app-uploads: bucket genérico para apps Uni+ (Fase 5)
#
# Per-app users + policies são responsabilidade da Fase 5 (cada app PR pede
# seu user via mc admin user add + policy attach).
step_data_bootstrap_minio_buckets() {
    if $SKIP_DOCKER && ! command -v docker &>/dev/null; then
        log_warn "Docker indisponível e --skip-docker ativo — pulando bucket bootstrap."
        return
    fi

    if ! sudo systemctl is-active --quiet uniplus-minio 2>/dev/null && ! $DRY_RUN; then
        log_warn "uniplus-minio não está ativo — pulando bucket bootstrap."
        return
    fi

    log_info "Pré-criando buckets baseline (keycloak-backups, loki-chunks, tempo-traces, app-uploads)..."

    local creds_file="$DATA_BASE/minio/.bootstrap-creds"

    if ! sudo test -f "$creds_file" 2>/dev/null; then
        if $DRY_RUN; then
            log_warn "Dry-run: bucket bootstrap precisaria de $creds_file"
            return
        fi
        log_warn "$creds_file ausente — buckets não criados (presume custódia já feita)."
        log_warn "Para re-rodar manualmente: ver docs/RUNBOOKS.md §12.5."
        return
    fi

    if $DRY_RUN; then
        echo "[DRY-RUN] mc alias set + mc mb keycloak-backups loki-chunks tempo-traces app-uploads"
        return
    fi

    local root_user root_pw
    root_user=$(sudo grep '^root_user=' "$creds_file" | cut -d= -f2)
    root_pw=$(sudo grep '^root_pw=' "$creds_file" | cut -d= -f2)
    if [[ -z "$root_user" || -z "$root_pw" ]]; then
        log_error "root_user ou root_pw vazio em $creds_file — não consigo criar buckets."
        exit 1
    fi

    # Credenciais via stdin (here-string + read -r no shell do container).
    # `mc alias set --quiet` evita echo do password no stdout.
    sudo docker run --rm -i --network host \
        --entrypoint sh \
        quay.io/minio/mc:latest -c '
            set -e
            read -r U
            read -r P
            mc --quiet alias set local http://10.0.2.87:9000 "$U" "$P"
            for b in keycloak-backups loki-chunks tempo-traces app-uploads; do
                mc mb --ignore-existing "local/$b"
            done
            mc ls local
        ' <<EOF
$root_user
$root_pw
EOF
    log_success "Buckets baseline pré-criados (idempotente)."
    unset root_user root_pw
}

# Configura Apache Kafka 4.2.0 (KRaft only — ZooKeeper removido em 4.0 GA) como
# container Docker gerenciado por systemd no data-host. Single-node combined
# (process.roles=broker,controller) com SASL_SSL + SCRAM-SHA-512 + StandardAuthorizer.
# Ver ADR-009 para a decisão de modelo de segurança.
#
# UID/GID: 1000:1000 (appuser, default user da imagem apache/kafka:4.2.0).
#
# Encryption: TLS 1.2/1.3 via cert PEM self-signed estático (validade 10 anos)
# gerado pelo bootstrap. Self-signed deliberado em standalone — cert-manager
# fica para hml/prod com secret-sync para data-host (extensão K8s não atinge
# nativamente container fora do cluster). Cert tem SAN cobrindo IP da subnet
# privada (10.0.2.87) + DNS interno (kafka.standalone.portaluni.com.br).
#
# Authentication: SCRAM-SHA-512 exclusivo (256 NIST-deprecated). Admin user
# `admin` embarcada via `kafka-storage.sh format --add-scram` no bootstrap
# inicial — sem isso há catch-22 (precisa autenticar pra criar usuário, mas
# não há usuário ainda). Per-app users criados na Fase 5 via kafka-configs.sh.
#
# Authorization: StandardAuthorizer (KRaft-native; AclAuthorizer da era ZK
# está deprecated em 4.x). `allow.everyone.if.no.acl.found=false` fail-closed;
# `super.users=User:admin` para ops sem ACL.
#
# Por que server.properties em vez de env vars: a imagem apache/kafka:4.2.0
# tem KafkaDockerWrapper que renderiza server.properties a partir de env vars
# `KAFKA_*`, mas a transformação não preserva hyphens — `SCRAM-SHA-512` em
# nome de listener fica inviável via env. Solução: gerar server.properties
# completo no bootstrap e montar via `--mounted-configs-dir` do entrypoint
# (mecanismo já existente para esse caso).
#
# Cluster ID + admin_pw persistidos em .bootstrap-creds (cluster_id NÃO é
# segredo; admin_pw É — custódia em Vault + shred opcional, mas se shredded
# regerar exige re-format do storage que destrói tópicos/mensagens).
#
# Idempotência:
#   - .bootstrap-creds: preserva (validando que tem ambos os campos novos);
#     gera se ausente; aborta se data dir formatado sem creds (mismatch).
#   - Certs: regenerados se ausentes; preservados em re-runs.
#   - Format do storage: roda explicitamente em container ad-hoc com --add-scram
#     ANTES do systemctl start na primeira run; entrypoint do uniplus-kafka
#     vê "already formatted" e skip nas runs subsequentes.
#   - server.properties + admin.properties + EnvironmentFile + systemd unit:
#     sempre re-aplicados (cheap, corrige drift).
#   - Serviço já ativo: não reinicia.
step_data_setup_kafka() {
    if $SKIP_DOCKER && ! command -v docker &>/dev/null; then
        log_warn "Docker indisponível e --skip-docker ativo — pulando setup do Kafka."
        return
    fi

    log_info "Configurando Kafka 4.2.0 KRaft + SASL_SSL + SCRAM-SHA-512 systemd..."

    local creds_file="$DATA_BASE/kafka/.bootstrap-creds"
    local certs_dir="/etc/uniplus-kafka/certs"
    local config_dir="/etc/uniplus-kafka/config"
    local server_props="$config_dir/server.properties"
    local admin_props="$DATA_BASE/kafka/admin.properties"
    local env_file="/etc/uniplus-kafka.env"
    local unit_file="/etc/systemd/system/uniplus-kafka.service"

    # Diretórios + ownership.
    # data dir 750 chown 1000:1000 (appuser do container).
    # certs_dir e config_dir 755 root:root — uid 1000 do container precisa
    # traverse para abrir os PEMs e o server.properties (lição PR #133 round 1).
    # Os files dentro têm mode próprio (PEMs 644, server.properties 600 chown
    # 1000:1000 pois contém SCRAM password em cleartext).
    run "sudo mkdir -p $DATA_BASE/kafka/data $certs_dir $config_dir"
    run "sudo chown 1000:1000 $DATA_BASE/kafka/data"
    run "sudo chmod 750 $DATA_BASE/kafka/data"
    run "sudo chown root:root $certs_dir $config_dir"
    run "sudo chmod 755 $certs_dir $config_dir"

    # Detectar inicialização prévia: meta.properties no data dir indica storage
    # formatado. Análogo a PG_VERSION (Postgres) e .minio.sys/ (MinIO).
    local already_initialized=false
    if ! $DRY_RUN && \
       sudo test -f "$DATA_BASE/kafka/data/meta.properties" 2>/dev/null; then
        already_initialized=true
    fi

    # ---- Decisão 1: .bootstrap-creds (preservar / gerar / abortar) ----
    # Formato novo (ADR-009): cluster_id + admin_pw. PR #137 originalmente só
    # tinha cluster_id; bootstrap antigo precisa migração explícita pelo
    # operador (ver §13.4 — backup do antigo, decidir nova admin pw, restore).
    if sudo test -f "$creds_file" 2>/dev/null; then
        # `grep -q` é robusto a multi-linha: retorna apenas exit code (0 se
        # encontra, 1 se não). Pattern anterior `grep -c | echo 0` quebrava
        # quando admin_pw ausente — grep imprime `0\n` E falha, `|| echo 0`
        # acrescenta `0\n`, valor final vira `"0\n0"` e o `[[ == "0" ]]`
        # não dispara, pulando a mensagem de migração explícita (Codex P2).
        if ! sudo grep -q '^admin_pw=' "$creds_file" 2>/dev/null; then
            log_error "$creds_file existe mas não contém admin_pw (formato pré-SASL/PR #137)."
            log_error "Migração ADR-009 exige reset do storage + novo .bootstrap-creds."
            log_error "Procedimento completo: docs/RUNBOOKS.md §13.1.1 (Migração PLAINTEXT → SASL_SSL)."
            exit 1
        fi
        log_success "Bootstrap creds Kafka já existentes (cluster_id + admin_pw) — preservando."
    elif $DRY_RUN; then
        log_warn "Dry-run: cluster_id + admin_pw seriam gerados em $creds_file"
    elif $already_initialized; then
        log_error "$creds_file ausente, mas $DATA_BASE/kafka/data/meta.properties já existe."
        log_error "Storage formatado mas creds shredded — restaure via docs/RUNBOOKS.md §13.4."
        exit 1
    else
        log_info "Gerando cluster_id + admin SCRAM-SHA-512 password..."
        local cluster_id admin_pw
        cluster_id=$(sudo docker run --rm --entrypoint /opt/kafka/bin/kafka-storage.sh \
            apache/kafka:4.2.0 random-uuid 2>/dev/null | tr -d '\r\n')
        if [[ -z "$cluster_id" ]]; then
            log_error "Falha ao gerar cluster_id via kafka-storage.sh."
            exit 1
        fi
        admin_pw=$(openssl rand -hex 32)
        sudo tee "$creds_file" >/dev/null <<EOF
cluster_id=$cluster_id
admin_pw=$admin_pw
EOF
        sudo chown root:root "$creds_file"
        sudo chmod 600 "$creds_file"
        log_warn "cluster_id + admin_pw gerados em $creds_file. Custódia obrigatória — ver §13.2."
    fi

    # ---- Decisão 2: Certs PEM (self-signed, 10 anos) ----
    # Preservados se TODOS os 4 arquivos PEM existem (server.crt, server.key,
    # ca.crt, server.pem bundle). Verificar só server.crt seria insuficiente:
    # bootstrap interrompido entre `openssl req` e `cat ... > server.pem`
    # deixaria server.crt presente mas server.pem ausente; re-run pularia a
    # geração e o broker falharia em startup (ssl.keystore.location aponta
    # pra arquivo inexistente). Codex P2 round 3.
    if sudo test -f "$certs_dir/server.crt" 2>/dev/null && \
       sudo test -f "$certs_dir/server.key" 2>/dev/null && \
       sudo test -f "$certs_dir/ca.crt" 2>/dev/null && \
       sudo test -f "$certs_dir/server.pem" 2>/dev/null; then
        log_success "Certs Kafka completos (crt/key/ca/pem) — preservando."
    elif $DRY_RUN; then
        log_warn "Dry-run: cert self-signed seria gerado em $certs_dir/"
    else
        log_info "Gerando cert self-signed PEM (10 anos, SAN: 10.0.2.87 + kafka.standalone.portaluni.com.br)..."
        # OpenSSL config inline com SAN multi-tipo (DNS + IP). Self-signed →
        # CA = cert (cadeia de 1 nível); ca.crt é cópia do server.crt.
        local ssl_cnf="$certs_dir/openssl.cnf"
        sudo tee "$ssl_cnf" >/dev/null <<'CNF'
[req]
distinguished_name = req_distinguished_name
prompt = no
req_extensions = v3_req

[req_distinguished_name]
CN = kafka.standalone.portaluni.com.br

[v3_req]
basicConstraints = CA:TRUE
keyUsage = digitalSignature, keyEncipherment, keyCertSign
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = kafka.standalone.portaluni.com.br
DNS.2 = localhost
IP.1 = 10.0.2.87
IP.2 = 127.0.0.1
CNF
        sudo openssl req -x509 -newkey rsa:2048 \
            -keyout "$certs_dir/server.key" \
            -out "$certs_dir/server.crt" \
            -days 3650 -nodes \
            -config "$ssl_cnf" \
            -extensions v3_req >/dev/null 2>&1
        sudo cp "$certs_dir/server.crt" "$certs_dir/ca.crt"
        # PEM keystore para Kafka 4.x exige cert + key concatenados num único
        # arquivo apontado por `ssl.keystore.location` (ou usar
        # `ssl.keystore.key` inline no server.properties — deixaria a private
        # key cleartext no config). Gerar `server.pem` concatenado é a forma
        # canônica documentada (Kafka KIP-651). NOTA: `ssl.keystore.key.location`
        # NÃO é uma propriedade válida — não confundir com truststore que tem
        # `location` para cert isolado.
        sudo bash -c "cat $certs_dir/server.crt $certs_dir/server.key > $certs_dir/server.pem"
        # uid 1000 do container precisa ler PEMs em startup.
        sudo chown 1000:1000 "$certs_dir/server.crt" "$certs_dir/server.key" \
                              "$certs_dir/ca.crt" "$certs_dir/server.pem"
        sudo chmod 644 "$certs_dir/server.crt" "$certs_dir/ca.crt"
        sudo chmod 600 "$certs_dir/server.key" "$certs_dir/server.pem"
        sudo rm -f "$ssl_cnf"
        log_warn "Cert self-signed gerado em $certs_dir/server.{crt,pem} (validade 10 anos)."
        log_warn "ca.crt deve ser distribuído pra clientes (apps Fase 5, AKHQ)."
    fi

    # ---- Decisão 3: Format inicial com --add-scram ----
    # Crítico: --add-scram só é honrado durante format inicial. Re-format
    # após formatação NÃO adiciona credenciais. Por isso fazemos format
    # explícito ANTES do systemctl start na 1ª run, em container ad-hoc.
    # O entrypoint do uniplus-kafka subsequente vê "already formatted" e skip.
    if ! $DRY_RUN && ! $already_initialized && sudo test -f "$creds_file"; then
        log_info "Format do storage com --add-scram (admin SCRAM-SHA-512 embarcada)..."
        local cluster_id_init admin_pw_init
        cluster_id_init=$(sudo grep '^cluster_id=' "$creds_file" | cut -d= -f2)
        admin_pw_init=$(sudo grep '^admin_pw=' "$creds_file" | cut -d= -f2)

        # server.properties mínimo só pra format (validar topology). NÃO usar
        # o $server_props final — ele tem JAAS/SCRAM cleartext que ainda não
        # foi gerado neste ponto da função (geração logo abaixo).
        # KafkaConfig.validateValues exige advertised.listeners + inter.broker.
        # listener.name presentes mesmo em format-time (broker ainda não inicia,
        # mas a config é parseada pra validar topologia).
        local fmt_props
        fmt_props=$(sudo mktemp)
        sudo tee "$fmt_props" >/dev/null <<EOF
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@10.0.2.87:9093
listeners=SASL_SSL://10.0.2.87:9092,CONTROLLER://10.0.2.87:9093
advertised.listeners=SASL_SSL://10.0.2.87:9092
controller.listener.names=CONTROLLER
inter.broker.listener.name=SASL_SSL
listener.security.protocol.map=CONTROLLER:SASL_SSL,SASL_SSL:SASL_SSL
log.dirs=/var/lib/kafka/data
EOF
        sudo chmod 644 "$fmt_props"

        # admin_pw_init aparece em /proc/<pid>/cmdline DO CONTAINER por ~1s
        # (--add-scram exige formato inline). Trade-off: container é
        # descartável, processo curto, namespace isolado. Se for dealbreaker
        # futuro: format manual + ALTER user via kafka-configs.sh.
        if ! sudo docker run --rm \
            -v "$DATA_BASE/kafka/data:/var/lib/kafka/data" \
            -v "$fmt_props:/opt/kafka/config/format.properties:ro" \
            --entrypoint /opt/kafka/bin/kafka-storage.sh \
            apache/kafka:4.2.0 \
            format --config /opt/kafka/config/format.properties \
                   --cluster-id "$cluster_id_init" \
                   --add-scram "SCRAM-SHA-512=[name=admin,password=$admin_pw_init]" \
                   --ignore-formatted >/dev/null 2>&1; then
            log_error "Format do storage falhou. Re-rode manualmente em verbose: docker run ... format ..."
            sudo rm -f "$fmt_props"
            exit 1
        fi
        sudo rm -f "$fmt_props"
        unset cluster_id_init admin_pw_init
        log_success "Storage formatado com admin SCRAM-SHA-512 embarcada."
    fi

    # ---- Decisão 4: server.properties (sempre re-aplicado) ----
    # Contém admin SCRAM password em cleartext em listener.name.*.sasl.jaas.config
    # (Kafka 4.x exige inline; não há mecanismo file-based para JAAS de listener
    # nessa versão). Mode 600 chown 1000:1000 — broker (uid 1000) lê; outros não.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $server_props com SASL_SSL + SCRAM + StandardAuthorizer"
    else
        local admin_pw_curr
        admin_pw_curr=$(sudo grep '^admin_pw=' "$creds_file" | cut -d= -f2)
        if [[ -z "$admin_pw_curr" ]]; then
            log_error "admin_pw vazio em $creds_file. Abortando."
            exit 1
        fi
        sudo tee "$server_props" >/dev/null <<EOF
# === KRaft topology (single-node combined) ===
process.roles=broker,controller
node.id=1
controller.quorum.voters=1@10.0.2.87:9093
listeners=SASL_SSL://10.0.2.87:9092,CONTROLLER://10.0.2.87:9093
advertised.listeners=SASL_SSL://10.0.2.87:9092
controller.listener.names=CONTROLLER
inter.broker.listener.name=SASL_SSL
listener.security.protocol.map=CONTROLLER:SASL_SSL,SASL_SSL:SASL_SSL

# === Storage ===
log.dirs=/var/lib/kafka/data
auto.create.topics.enable=false

# === Replication factor 1 (single-node, sem replicação) ===
offsets.topic.replication.factor=1
transaction.state.log.replication.factor=1
transaction.state.log.min.isr=1
share.coordinator.state.topic.replication.factor=1
share.coordinator.state.topic.min.isr=1

# === SASL/SCRAM-SHA-512 (admin embarcada via --add-scram no format) ===
sasl.enabled.mechanisms=SCRAM-SHA-512
sasl.mechanism.inter.broker.protocol=SCRAM-SHA-512
sasl.mechanism.controller.protocol=SCRAM-SHA-512
listener.name.sasl_ssl.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="$admin_pw_curr";
listener.name.controller.scram-sha-512.sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="$admin_pw_curr";

# === TLS (PEM keystore + truststore; self-signed = ca = cert) ===
# server.pem: cert + private key concatenados (formato PEM bundle padrão Kafka 4.x).
# ssl.keystore.location aponta para o bundle; broker lê o PEM e separa
# internamente. NÃO há propriedade ssl.keystore.key.location válida — usar
# bundle ou ssl.keystore.key inline (rejeitado: cleartext no server.properties).
ssl.keystore.type=PEM
ssl.keystore.location=/etc/kafka/secrets/server.pem
ssl.truststore.type=PEM
ssl.truststore.location=/etc/kafka/secrets/ca.crt
ssl.client.auth=none

# === StandardAuthorizer (KRaft-native; fail-closed) ===
authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer
super.users=User:admin
allow.everyone.if.no.acl.found=false
EOF
        sudo chown 1000:1000 "$server_props"
        sudo chmod 600 "$server_props"
        unset admin_pw_curr
    fi

    # ---- Decisão 5: admin.properties (CLI tools como admin) ----
    # Padrão para `kafka-topics.sh --command-config admin.properties`,
    # `kafka-acls.sh --command-config ...`, `kafka-configs.sh --command-config ...`.
    # Mode 600 chown 1000:1000 — uid do container kafka tools precisa ler quando
    # rodado via `docker run -v admin.properties:/tmp/...`. Mount preserva perms
    # do host; sem chown 1000:1000 o probe falha com AccessDeniedException.
    # Mesmo pattern do server.properties (que também tem SCRAM cleartext).
    if ! $DRY_RUN; then
        local admin_pw_props
        admin_pw_props=$(sudo grep '^admin_pw=' "$creds_file" | cut -d= -f2)
        sudo tee "$admin_props" >/dev/null <<EOF
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="$admin_pw_props";
ssl.truststore.type=PEM
ssl.truststore.location=$certs_dir/ca.crt
ssl.endpoint.identification.algorithm=
EOF
        sudo chown 1000:1000 "$admin_props"
        sudo chmod 600 "$admin_props"
        unset admin_pw_props
    fi

    # ---- Decisão 6: EnvironmentFile (mínimo — só CLUSTER_ID + JVM heap) ----
    # Toda config sensível e de listener vai em server.properties (file-based).
    # CLUSTER_ID precisa estar no env do container (entrypoint exige); JVM
    # heap fica aqui pra rotação trivial sem regerar config.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $env_file"
    else
        local cluster_id_env
        cluster_id_env=$(sudo grep '^cluster_id=' "$creds_file" | cut -d= -f2)
        sudo tee "$env_file" >/dev/null <<EOF
CLUSTER_ID=$cluster_id_env
KAFKA_HEAP_OPTS="-Xmx1g -Xms1g"
EOF
        sudo chown root:root "$env_file"
        sudo chmod 600 "$env_file"
        unset cluster_id_env
    fi

    # ---- Decisão 7: systemd unit ----
    # Mount config_dir como /mnt/shared/config no container — KafkaDockerWrapper
    # setup picks up server.properties dali e merge com defaults; certs como
    # /etc/kafka/secrets ro; data dir como /var/lib/kafka/data.
    if $DRY_RUN; then
        echo "[DRY-RUN] Escreveria $unit_file"
    else
        sudo tee "$unit_file" >/dev/null <<'UNIT'
[Unit]
Description=Uni+ Apache Kafka 4.2.0 KRaft (SASL_SSL + SCRAM-SHA-512)
Documentation=https://github.com/unifesspa-edu-br/uniplus-infra/blob/main/docs/RUNBOOKS.md
After=docker.service network-online.target
Requires=docker.service
Wants=network-online.target

[Service]
Type=simple
Restart=always
RestartSec=10
TimeoutStartSec=180
EnvironmentFile=/etc/uniplus-kafka.env

ExecStartPre=-/usr/bin/docker rm -f uniplus-kafka
ExecStart=/usr/bin/docker run --rm --name uniplus-kafka \
  --network host \
  -e CLUSTER_ID \
  -e KAFKA_HEAP_OPTS \
  -v /var/lib/uniplus/kafka/data:/var/lib/kafka/data \
  -v /etc/uniplus-kafka/config:/mnt/shared/config:ro \
  -v /etc/uniplus-kafka/certs:/etc/kafka/secrets:ro \
  apache/kafka:4.2.0

ExecStop=/usr/bin/docker stop -t 30 uniplus-kafka

[Install]
WantedBy=multi-user.target
UNIT
    fi

    run "sudo systemctl daemon-reload"
    run "sudo systemctl enable uniplus-kafka"

    if $DRY_RUN; then
        echo "[DRY-RUN] systemctl start uniplus-kafka + SASL_SSL broker-api-versions probe"
    elif sudo systemctl is-active --quiet uniplus-kafka; then
        log_success "uniplus-kafka já ativo — preservando state (sem restart)."
    else
        sudo systemctl start uniplus-kafka
        log_info "Aguardando Kafka aceitar conexões SASL_SSL (cold start ~30-90s)..."
        local attempts=0
        # broker-api-versions agora exige --command-config com cliente SASL_SSL.
        # admin.properties tem JAAS + truststore PEM. Container ad-hoc com
        # mount do file e do CA cert — não invade o uniplus-kafka.
        until sudo docker run --rm --network host \
                -v "$admin_props:/tmp/admin.properties:ro" \
                -v "$certs_dir/ca.crt:$certs_dir/ca.crt:ro" \
                --entrypoint /opt/kafka/bin/kafka-broker-api-versions.sh \
                apache/kafka:4.2.0 \
                --bootstrap-server 10.0.2.87:9092 \
                --command-config /tmp/admin.properties &>/dev/null; do
            attempts=$(( attempts + 1 ))
            if (( attempts >= 36 )); then
                log_error "Kafka SASL_SSL não respondeu broker-api-versions em 180s."
                log_error "Ver: sudo journalctl -u uniplus-kafka -n 100"
                exit 1
            fi
            sleep 5
        done
        log_success "uniplus-kafka ativo + SASL_SSL broker-api-versions OK."
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
    echo "  systemctl status uniplus-minio"
    echo "  systemctl status uniplus-kafka"
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
    echo "  MinIO — runbook §12.2:"
    echo "    1. Ler:        sudo cat $DATA_BASE/minio/.bootstrap-creds"
    echo "    2. Custodiar:  Vault (secret/standalone/minio/root) + gestor institucional"
    echo "    3. Limpar:     sudo shred -u $DATA_BASE/minio/.bootstrap-creds"
    echo "  Kafka — runbook §13.2 (admin SCRAM password é segredo, cluster_id NÃO):"
    echo "    1. Ler:        sudo cat $DATA_BASE/kafka/.bootstrap-creds"
    echo "    2. Custodiar:  Vault (secret/standalone/kafka/admin) — admin_pw"
    echo "    3. Registrar:  Vault (secret/standalone/kafka/cluster) — cluster_id (auditoria)"
    echo "    4. CA cert pra clients: /etc/uniplus-kafka/certs/ca.crt (distribuir pra apps Fase 5 + AKHQ)"
    echo ""
    echo "Validar:"
    echo "  df -h $DATA_BASE/*"
    echo "  sudo vgs && sudo lvs"
    echo "  sudo docker exec uniplus-postgres pg_isready -U postgres"
    echo "  sudo docker exec -i uniplus-redis sh -c 'read -r P; REDISCLI_AUTH=\$P redis-cli ping' \\"
    echo "    <<<\"\$(sudo grep ^default_pw= $DATA_BASE/redis/.bootstrap-creds | cut -d= -f2)\""
    echo "  curl -sf http://10.0.2.87:9000/minio/health/live && echo ' — MinIO health OK'"
    echo "  sudo docker run --rm --network host \\"
    echo "    -v $DATA_BASE/kafka/admin.properties:/tmp/admin.properties:ro \\"
    echo "    -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \\"
    echo "    --entrypoint /opt/kafka/bin/kafka-broker-api-versions.sh \\"
    echo "    apache/kafka:4.2.0 --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties | head -3"
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
        step_data_setup_minio
        step_data_bootstrap_minio_buckets
        step_data_setup_kafka
        summary_data
        ;;
esac
