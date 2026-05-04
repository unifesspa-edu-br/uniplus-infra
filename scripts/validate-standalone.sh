#!/usr/bin/env bash
# ============================================================================
# validate-standalone.sh
#
# Valida saúde do ambiente standalone Uni+ (k8s-host + data-host OCI).
# Executar no k8s-host após bootstrap-standalone.sh.
#
# Uso:
#   ./validate-standalone.sh
#   DATA_HOST_IP=10.0.2.87 SSH_KEY=~/.ssh/id_ed25519 ./validate-standalone.sh
#
# Saída: 0 se nenhum check crítico falhou; 1 se houver falhas críticas.
# ============================================================================

set -uo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0
WARNINGS=0

# data-host: subnet privada OCI — sobrepor via env se necessário
DATA_HOST_IP="${DATA_HOST_IP:-10.0.2.87}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_OPTS="-i $SSH_KEY -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"

check() {
    local name=$1 cmd=$2
    if eval "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $name"
        ((PASSED++)) || true
    else
        echo -e "  ${RED}✗${NC} $name"
        ((FAILED++)) || true
    fi
}

check_warn() {
    local name=$1 cmd=$2
    if eval "$cmd" &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} $name"
        ((PASSED++)) || true
    else
        echo -e "  ${YELLOW}⚠${NC} $name (aviso)"
        ((WARNINGS++)) || true
    fi
}

echo "============================================"
echo "  Validação Standalone Uni+"
echo "  data-host: $DATA_HOST_IP"
echo "============================================"
echo ""

# ── Pré-requisitos ────────────────────────────────────────────────────────────
echo "→ Pré-requisitos (k8s-host):"
check      "kubectl disponível"               "command -v kubectl"
check      "helm disponível"                  "command -v helm"
check_warn "nc disponível (testes de porta)"  "command -v nc"
echo ""

# ── K3s ───────────────────────────────────────────────────────────────────────
echo "→ K3s:"
check      "API server acessível"                  "kubectl cluster-info"
check      "Node uniplus-standalone Ready"          "kubectl get nodes | grep -q 'uniplus-standalone.*Ready'"
check      "kube-system pods Running"               "kubectl get pods -n kube-system --field-selector=status.phase=Running -o name | grep -q pod"
check_warn "Traefik rodando"                        "kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik | grep -q Running"
echo ""

# ── ArgoCD ───────────────────────────────────────────────────────────────────
echo "→ ArgoCD:"
check      "namespace argocd existe"                           "kubectl get namespace argocd"
check      "argocd-server Running"                             "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server | grep -q Running"
check      "argocd-repo-server Running"                        "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server | grep -q Running"
check      "argocd-applicationset-controller Running"          "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller | grep -q Running"
check_warn "argocd-application-controller Running"             "kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-application-controller | grep -q Running"
echo ""

# ── Vault (a provisionar via story #64) ──────────────────────────────────────
echo "→ Vault (OCI KMS auto-unseal — a provisionar):"
check_warn "namespace vault existe"    "kubectl get namespace vault"
check_warn "vault-0 Running"           "kubectl get pods -n vault -l app.kubernetes.io/name=vault | grep -q Running"
check_warn "Vault unsealed"            "kubectl exec -n vault vault-0 -- vault status 2>/dev/null | grep -q 'Sealed.*false'"
echo ""

# ── Conectividade k8s-host → data-host ───────────────────────────────────────
echo "→ Conectividade k8s-host → data-host ($DATA_HOST_IP):"
check      "data-host alcançável (ICMP)"  "ping -c 1 -W 3 $DATA_HOST_IP"
check_warn "Postgres  (5432)"             "nc -z -w 3 $DATA_HOST_IP 5432"
check_warn "Kafka     (9092)"             "nc -z -w 3 $DATA_HOST_IP 9092"
check_warn "MinIO API (9000)"             "nc -z -w 3 $DATA_HOST_IP 9000"
check_warn "Vault     (8200)"             "nc -z -w 3 $DATA_HOST_IP 8200"
check_warn "Redis     (6379)"             "nc -z -w 3 $DATA_HOST_IP 6379"
echo ""

# ── Volumes LVM no data-host (via SSH) ───────────────────────────────────────
echo "→ Volumes LVM no data-host:"
check      "SSH ao data-host disponível"     "ssh $SSH_OPTS ubuntu@$DATA_HOST_IP true"
check_warn "postgres montado"                "ssh $SSH_OPTS ubuntu@$DATA_HOST_IP 'mountpoint -q /var/lib/uniplus/postgres'"
check_warn "kafka montado"                   "ssh $SSH_OPTS ubuntu@$DATA_HOST_IP 'mountpoint -q /var/lib/uniplus/kafka'"
check_warn "minio montado"                   "ssh $SSH_OPTS ubuntu@$DATA_HOST_IP 'mountpoint -q /var/lib/uniplus/minio'"
check_warn "vault montado"                   "ssh $SSH_OPTS ubuntu@$DATA_HOST_IP 'mountpoint -q /var/lib/uniplus/vault'"
check_warn "redis dir presente"              "ssh $SSH_OPTS ubuntu@$DATA_HOST_IP 'test -d /var/lib/uniplus/redis'"
echo ""

# ── DNS e conectividade externa ───────────────────────────────────────────────
echo "→ DNS e conectividade externa:"
check_warn "standalone.portaluni.com.br resolve"  "getent hosts standalone.portaluni.com.br"
check_warn "Internet (Cloudflare DNS)"             "curl -m 5 -s https://1.1.1.1 -o /dev/null"
check_warn "GitHub acessível"                      "curl -m 5 -s https://github.com -o /dev/null"
check_warn "Docker Hub acessível"                  "curl -m 5 -s https://registry-1.docker.io -o /dev/null"
echo ""

# ── Resumo ────────────────────────────────────────────────────────────────────
echo "============================================"
TOTAL=$((PASSED + FAILED + WARNINGS))
echo "  Resumo: $PASSED OK, $FAILED ERROS, $WARNINGS AVISOS (total: $TOTAL)"
echo "============================================"

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
