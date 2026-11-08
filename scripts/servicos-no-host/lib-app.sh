#!/usr/bin/env bash
# Rotinas da VM de aplicação de produção compartilhadas por bootstrap-app.sh e
# atualizar-producao.sh. Carregado com `source`, depois de lib-comum.sh.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AMBIENTE="prod-standalone"
# Nome do cluster no ArgoCD; o ApplicationSet o usa como sufixo das Applications.
NOME_DO_CLUSTER="in-cluster"
# Namespaces que servem rotas com o certificado do domínio.
NAMESPACES_TLS=(uniplus geo traefik vault minio-console-proxy argocd)
TLS_SECRET_NAME="uniplus-unifesspa-tls"

# Confere que a revisão é uma tag existente deste repositório e que o checkout
# local está exatamente nela: o que se aplica é o que a tag contém.
validar_revisao() {
    local revisao="$1"
    [[ "$revisao" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || {
        log_error "Revisão inválida: use uma tag no formato vX.Y.Z (recebido: '$revisao')."
        exit 2
    }
    $DRY_RUN && return 0
    git -C "$REPO_ROOT" rev-parse -q --verify "refs/tags/$revisao" >/dev/null || {
        log_error "A tag $revisao não existe neste checkout; rode 'git fetch --tags'."
        exit 1
    }
    [[ "$(git -C "$REPO_ROOT" rev-parse "refs/tags/$revisao^{commit}")" == "$(git -C "$REPO_ROOT" rev-parse HEAD)" ]] || {
        log_error "O checkout não está na tag $revisao; faça 'git checkout $revisao' antes."
        exit 1
    }
}

# Cria os namespaces e copia o Secret TLS do domínio para cada um (mesma
# identidade, nunca certificado novo por namespace).
publicar_segredo_tls() {
    local ns
    exigir_par_tls
    for ns in "${NAMESPACES_TLS[@]}"; do
        run "kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -"
        run "sudo kubectl --kubeconfig $HOME/.kube/config -n $ns create secret tls $TLS_SECRET_NAME --cert=$TLS_BUNDLE --key=$TLS_KEY --dry-run=client -o yaml | kubectl apply -f -"
    done
}

# O cluster é declarado em Secret, com o label da revisão que o ApplicationSet
# lê (sem ele a geração das Applications de produção falha de propósito).
registrar_cluster() {
    local revisao="$1"
    local manifesto
    manifesto=$(cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$NOME_DO_CLUSTER
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    environment: $AMBIENTE
    uniplus.io/managed: "true"
    uniplus.io/revision: $revisao
type: Opaque
stringData:
  name: $NOME_DO_CLUSTER
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML
)
    if $DRY_RUN; then
        echo "[DRY-RUN] kubectl apply do Secret de cluster (environment=$AMBIENTE, uniplus.io/revision=$revisao)"
    else
        printf '%s\n' "$manifesto" | kubectl apply -f -
    fi
}

# Aplica o projeto, os ApplicationSets e o verificador na revisão dada. Nada é
# sincronizado: as Applications nascem à espera do sync manual.
aplicar_argocd() {
    local revisao="$1"
    run "kubectl apply -f $REPO_ROOT/argocd/project.yaml"
    run "kubectl apply -f $REPO_ROOT/argocd/applicationset.yaml"
    if $DRY_RUN; then
        echo "[DRY-RUN] kubectl apply de argocd/applications/verificador-prod.yaml com REVISAO_UNIPLUS_INFRA=$revisao"
    else
        sed "s/REVISAO_UNIPLUS_INFRA/$revisao/" "$REPO_ROOT/argocd/applications/verificador-prod.yaml" \
            | kubectl apply -f -
    fi
}
