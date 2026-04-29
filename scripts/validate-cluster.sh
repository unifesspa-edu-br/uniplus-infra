#!/usr/bin/env bash
# ============================================================================
# validate-cluster.sh
#
# Valida saúde do cluster Uni+. Use após bootstrap ou para diagnóstico.
# ============================================================================

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

check() {
    local name=$1
    local cmd=$2
    
    if eval "$cmd" &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} $name"
        ((PASSED++)) || true
    else
        echo -e "  ${RED}✗${NC} $name"
        ((FAILED++)) || true
    fi
}

check_warn() {
    local name=$1
    local cmd=$2
    
    if eval "$cmd" &> /dev/null; then
        echo -e "  ${GREEN}✓${NC} $name"
        ((PASSED++)) || true
    else
        echo -e "  ${YELLOW}⚠${NC} $name"
        ((WARNINGS++)) || true
    fi
}

echo "============================================"
echo "  Validação do Lab Uni+"
echo "============================================"
echo ""

echo "→ Pré-requisitos do sistema:"
check "Docker instalado e rodando" "docker info"
check "Helm instalado" "command -v helm"
check_warn "kubectl disponível" "command -v kubectl"
check_warn "k9s disponível" "command -v k9s"
echo ""

echo "→ Cluster Kubernetes:"
check "API server acessível" "kubectl cluster-info"
check "Nodes Ready" "kubectl get nodes | grep -q ' Ready '"
check "kube-system pods rodando" "kubectl get pods -n kube-system --field-selector=status.phase=Running -o name | head -1 | grep -q pod"
check_warn "Traefik rodando" "kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik | grep -q Running"
echo ""

echo "→ ArgoCD:"
check_warn "Namespace argocd existe" "kubectl get namespace argocd"
check_warn "argocd-server rodando" "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server | grep -q Running"
check_warn "argocd-application-controller rodando" "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-application-controller | grep -q Running"
echo ""

echo "→ Componentes no host (Docker):"
check_warn "Postgres rodando" "docker ps --format '{{.Names}}' | grep -q postgres"
check_warn "Kafka rodando" "docker ps --format '{{.Names}}' | grep -q kafka"
check_warn "MinIO rodando" "docker ps --format '{{.Names}}' | grep -q minio"
echo ""

echo "→ Cloudflare Tunnel:"
check_warn "cloudflared instalado" "command -v cloudflared"
check_warn "cloudflared service ativo" "systemctl is-active cloudflared"
echo ""

echo "→ Conectividade:"
check_warn "Internet (Cloudflare DNS)" "curl -m 5 -s https://1.1.1.1 -o /dev/null"
check_warn "GitHub acessível" "curl -m 5 -s https://github.com -o /dev/null"
check_warn "Docker Hub acessível" "curl -m 5 -s https://registry-1.docker.io -o /dev/null"
echo ""

# Outro DC (se aplicável)
if [[ "${HOSTNAME:-}" == "uniplus-sp1" ]]; then
    check_warn "Outro DC alcançável (uniplus-sp2)" "ping -c 1 -W 2 uniplus-sp2"
elif [[ "${HOSTNAME:-}" == "uniplus-sp2" ]]; then
    check_warn "Outro DC alcançável (uniplus-sp1)" "ping -c 1 -W 2 uniplus-sp1"
fi

echo ""
echo "============================================"
TOTAL=$((PASSED + FAILED + WARNINGS))
echo "  Resumo: $PASSED OK, $FAILED ERROS, $WARNINGS AVISOS (total: $TOTAL)"
echo "============================================"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
