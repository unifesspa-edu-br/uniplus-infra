#!/usr/bin/env bash
# Bootstrap da VM de aplicação de produção (uniplus-prod-app): K3s, Helm e ArgoCD,
# o Secret TLS do domínio nos namespaces, o registro do cluster na revisão
# informada e a aplicação dos ApplicationSets. Traefik, Vault, External Secrets,
# KES e as aplicações são instalados pelo ArgoCD, por sync manual.
#
# Uso:
#   ./bootstrap-app.sh --revisao=vX.Y.Z [--dry-run]
#
# A revisão é uma tag deste repositório já validada em homologação, e o checkout
# precisa estar nela. Pré-requisitos: Ubuntu 24.04, usuário com sudo sem senha
# (não root) e o par do certificado curinga em /etc/uniplus/tls. Sem Docker: o
# K3s usa containerd. Inicializar o Vault (Shamir 5/3) é manual, fora do script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-app.sh
source "$SCRIPT_DIR/lib-app.sh"

K3S_VERSION="v1.36.2+k3s1"
HELM_VERSION="v3.21.2"
ARGOCD_VERSION="v2.14.3"
REVISAO=""
APP_FQDN="${APP_FQDN:-uniplus-prod-app.unifesspa.edu.br}"
PORTA_KES=7373

mostrar_uso() {
    echo "Uso: $0 --revisao=vX.Y.Z [--dry-run]"
}

analisar_revisao() {
    local resto=() arg
    for arg in "$@"; do
        case "$arg" in
            --revisao=*) REVISAO="${arg#--revisao=}" ;;
            *) resto+=("$arg") ;;
        esac
    done
    analisar_argumentos "${resto[@]}"
    [[ -n "$REVISAO" ]] || { mostrar_uso >&2; exit 2; }
}

step_k3s() {
    if command -v k3s >/dev/null 2>&1; then
        log_success "K3s já instalado."
    else
        run "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION sh -s - \
            --node-name uniplus-prod-app \
            --tls-san $APP_IP --tls-san $APP_FQDN \
            --disable servicelb --disable traefik \
            --write-kubeconfig-mode 600"
    fi
    run "sudo chmod 600 /etc/rancher/k3s/k3s.yaml"
    run "install -d -m 700 $HOME/.kube"
    run "sudo install -m 600 -o $(id -u) -g $(id -g) /etc/rancher/k3s/k3s.yaml $HOME/.kube/config"
    export KUBECONFIG="$HOME/.kube/config"
}

step_helm() {
    if command -v helm >/dev/null 2>&1; then
        log_success "Helm já instalado."
        return 0
    fi
    local arquivo="helm-${HELM_VERSION}-linux-amd64.tar.gz" dir="$HOME/tmp/prod"
    run "install -d -m 700 $dir"
    run "curl -fsSL https://get.helm.sh/$arquivo -o $dir/$arquivo"
    run "curl -fsSL https://get.helm.sh/$arquivo.sha256sum -o $dir/$arquivo.sha256sum"
    run "cd $dir && sha256sum -c $arquivo.sha256sum"
    run "tar -xzf $dir/$arquivo -C $dir linux-amd64/helm && sudo install $dir/linux-amd64/helm /usr/local/bin/helm"
    run "rm -rf $dir/linux-amd64 $dir/$arquivo $dir/$arquivo.sha256sum"
}

step_argocd() {
    run "kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -"
    run "kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$ARGOCD_VERSION/manifests/install.yaml"
    run "kubectl wait --for=condition=available --timeout=300s -n argocd \
        deployment/argocd-server deployment/argocd-repo-server deployment/argocd-applicationset-controller"
    # O Traefik termina o TLS; o servidor atende em HTTP dentro do cluster.
    run "kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
        -p '{\"data\":{\"controller.diff.server.side\":\"true\",\"server.insecure\":\"true\"}}'"
    run "kubectl -n argocd rollout restart statefulset/argocd-application-controller deployment/argocd-server"
    run "kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s"
}

step_firewall() {
    if ! $DRY_RUN && ! sudo ufw status | grep -q '^Status: active'; then
        log_warn "ufw inativo: ligue-o, liberando antes SSH, 80 e 443, e rode de novo."
        return 0
    fi
    # O MinIO da VM de infraestrutura chega ao KES por TLS mútuo nesta porta.
    run "sudo ufw allow from $INFRA_IP to any port $PORTA_KES proto tcp"
}

resumo() {
    cat <<RESUMO

Aplicação preparada na revisão $REVISAO. Próximos passos (ver docs/RUNBOOKS.md):
  1. Sincronizar, na ordem, traefik, external-secrets e vault pelo ArgoCD.
  2. Inicializar e abrir o Vault (Shamir 5/3), fora dos scripts.
  3. Na VM de infraestrutura: semear-vault.sh, provisionar-bancos.sh,
     provisionar-verificacao.sh e provisionar-rabbitmq.sh.
  4. Aplicar a rota do ArgoCD: kubectl apply -f environments/prod-standalone/argocd-ingressroute.yaml
  5. Sincronizar as demais Applications.
Porta $PORTA_KES liberada para $INFRA_IP (KES, usada pelo MinIO).
RESUMO
}

analisar_revisao "$@"
exigir_usuario_comum
validar_revisao "$REVISAO"
step_k3s
step_helm
step_argocd
publicar_segredo_tls
registrar_cluster "$REVISAO"
aplicar_argocd "$REVISAO"
step_firewall
resumo
