#!/usr/bin/env bash
# ============================================================================
# teardown-lab.sh
#
# Remove o laboratório ou o ambiente standalone. CUIDADO: destrói dados.
#
# Uso:
#   ./teardown-lab.sh                          # lab genérico (sp1/sp2/pa1)
#   ./teardown-lab.sh --role=standalone-k8s    # k8s-host OCI
#   ./teardown-lab.sh --role=standalone-data   # data-host OCI
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

DATA_BASE="/var/lib/uniplus"

# ============== Parse args ==============
ROLE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role=*) ROLE="${1#*=}"; shift ;;
        -h|--help)
            echo "Uso: $0 [--role=standalone-k8s|standalone-data]"
            echo "  Sem --role: teardown genérico do laboratório (sp1/sp2/pa1)."
            exit 0
            ;;
        *) echo -e "${RED}Opção inválida: $1${NC}" >&2; exit 1 ;;
    esac
done

if [[ -n "$ROLE" && "$ROLE" != "standalone-k8s" && "$ROLE" != "standalone-data" ]]; then
    echo -e "${RED}Role inválido: '$ROLE'. Use standalone-k8s ou standalone-data.${NC}" >&2
    exit 1
fi

# ============== Helpers ==============
confirm() {
    read -rp "Tem CERTEZA? Digite 'CONFIRMO' para prosseguir: " answer
    if [[ "$answer" != "CONFIRMO" ]]; then
        echo "Operação cancelada."
        exit 0
    fi
    echo ""
}

# ============================================================================
# standalone-k8s
# ============================================================================
teardown_standalone_k8s() {
    echo -e "${RED}⚠️  TEARDOWN standalone-k8s${NC}"
    echo ""
    echo "Esta operação irá:"
    echo "  - Desinstalar K3s e apagar todo o estado do cluster"
    echo "  - Remover ~/.kube/config"
    echo "  - Parar cloudflared (se ativo)"
    echo ""
    echo -e "${YELLOW}Não afeta volumes de dados do data-host.${NC}"
    echo ""
    confirm

    if command -v k3s-uninstall.sh &>/dev/null; then
        echo "→ Desinstalando K3s..."
        sudo /usr/local/bin/k3s-uninstall.sh || true
    else
        echo "  K3s não encontrado. Pulando."
    fi

    if [[ -f "$HOME/.kube/config" ]]; then
        echo "→ Removendo kubeconfig..."
        rm -f "$HOME/.kube/config"
    fi

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        echo "→ Parando cloudflared..."
        sudo systemctl stop cloudflared
        sudo systemctl disable cloudflared
    fi

    if command -v helm &>/dev/null; then
        echo "→ Removendo Helm..."
        sudo rm -f /usr/local/bin/helm
    fi

    echo ""
    echo -e "${GREEN}Teardown standalone-k8s concluído.${NC}"
    echo "Re-bootstrap: ./scripts/bootstrap-standalone.sh --role=standalone-k8s"
}

# ============================================================================
# standalone-data
# ============================================================================
teardown_standalone_data() {
    echo -e "${RED}⚠️  TEARDOWN standalone-data${NC}"
    echo ""
    echo "Esta operação irá:"
    echo "  - Parar e remover todos os containers Docker"
    echo "  - Remover volumes Docker"
    echo "  - Desmontar volumes LVM de $DATA_BASE/{postgres,kafka,minio,vault}"
    echo "  - Remover entradas do /etc/fstab"
    echo ""
    echo -e "${YELLOW}Dados nos block volumes OCI são PRESERVADOS (LVM intacto, apenas desmontado).${NC}"
    echo ""
    confirm

    if command -v docker &>/dev/null; then
        echo "→ Parando containers Docker..."
        docker ps -aq | xargs -r docker stop || true
        docker ps -aq | xargs -r docker rm  || true
        echo "→ Removendo volumes Docker..."
        docker volume prune -f || true
    else
        echo "  Docker não encontrado. Pulando remoção de containers."
    fi

    echo "→ Desmontando volumes LVM..."
    for svc in postgres kafka minio vault; do
        if mountpoint -q "$DATA_BASE/$svc" 2>/dev/null; then
            sudo umount "$DATA_BASE/$svc"
            echo "  Desmontado: $DATA_BASE/$svc"
        else
            echo "  $DATA_BASE/$svc não estava montado. Pulando."
        fi
    done

    echo "→ Removendo entradas do /etc/fstab..."
    for vg in vg-postgres vg-kafka vg-minio vg-vault; do
        sudo sed -i "\|/dev/$vg|d" /etc/fstab
    done

    echo ""
    echo -e "${GREEN}Teardown standalone-data concluído.${NC}"
    echo -e "${YELLOW}Dados nos block volumes OCI foram preservados.${NC}"
    echo "Re-bootstrap: ./scripts/bootstrap-standalone.sh --role=standalone-data"
}

# ============================================================================
# Genérico (lab sp1/sp2/pa1) — comportamento original preservado
# ============================================================================
teardown_generic() {
    echo -e "${RED}⚠️  TEARDOWN DO LABORATÓRIO UNI+${NC}"
    echo ""
    echo "Esta operação irá:"
    echo "  - Parar e remover todos os containers"
    echo "  - Desinstalar K3s"
    echo "  - Remover volumes Docker (perda de dados!)"
    echo "  - Remover Cloudflare Tunnel local"
    echo ""
    echo -e "${YELLOW}Backups e dados em /var/lib/postgres, /var/lib/kafka e /var/lib/minio NÃO serão removidos.${NC}"
    echo ""
    confirm

    echo "Iniciando teardown..."

    echo "→ Parando containers Docker..."
    docker ps -aq | xargs -r docker stop || true
    docker ps -aq | xargs -r docker rm  || true

    echo "→ Removendo volumes Docker..."
    docker volume prune -f || true

    if command -v k3s-uninstall.sh &>/dev/null; then
        echo "→ Desinstalando K3s..."
        sudo /usr/local/bin/k3s-uninstall.sh || true
    fi

    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        echo "→ Parando cloudflared..."
        sudo systemctl stop cloudflared
        sudo systemctl disable cloudflared
    fi

    echo ""
    echo "Teardown completo."
    echo ""
    echo "Dados em /var/lib/postgres, /var/lib/kafka e /var/lib/minio foram preservados."
    echo "Para remover manualmente: sudo rm -rf /var/lib/{postgres,kafka,minio}/*"
}

# ============================================================================
# Main
# ============================================================================
case "$ROLE" in
    standalone-k8s)  teardown_standalone_k8s ;;
    standalone-data) teardown_standalone_data ;;
    "")              teardown_generic ;;
esac
