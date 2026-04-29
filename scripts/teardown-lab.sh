#!/usr/bin/env bash
# ============================================================================
# teardown-lab.sh
#
# Remove o laboratório completamente. CUIDADO: destrói dados.
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

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
read -rp "Tem CERTEZA que quer continuar? Digite 'CONFIRMO' para prosseguir: " confirm

if [[ "$confirm" != "CONFIRMO" ]]; then
    echo "Operação cancelada."
    exit 0
fi

echo ""
echo "Iniciando teardown..."

# Parar containers
echo "→ Parando containers Docker..."
docker ps -aq | xargs -r docker stop || true
docker ps -aq | xargs -r docker rm || true

# Remover volumes (apenas Docker, não os do host)
echo "→ Removendo volumes Docker..."
docker volume prune -f || true

# Desinstalar K3s
if command -v k3s-uninstall.sh &> /dev/null; then
    echo "→ Desinstalando K3s..."
    sudo /usr/local/bin/k3s-uninstall.sh || true
fi

# Cloudflared
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
