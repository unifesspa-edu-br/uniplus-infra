#!/usr/bin/env bash
# Rotinas da VM de aplicação de produção compartilhadas por bootstrap-app.sh,
# primeiro-sync.sh e renovar-certificado.sh. Carregado com `source`, depois de
# lib-comum.sh.

NOME_DO_AMBIENTE="uniplus-$AMBIENTE"
# Namespaces que servem rotas com o certificado do domínio.
NAMESPACES_TLS=(uniplus geo traefik vault minio-console-proxy argocd kafka-ui redis-ui apicurio-registry)
TLS_SECRET_NAME="uniplus-unifesspa-tls"

# O bootstrap da VM de aplicação só serve à produção: a homologação tem o próprio.
exigir_producao() {
    [[ "$AMBIENTE" == prd ]] && return 0
    log_error "$(basename "$0") só instala a produção (AMBIENTE=prd); recebido: '$AMBIENTE'."
    exit 2
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

# O cluster é declarado em Secret, com os labels de ambiente que os
# ApplicationSets do repositório de implantação usam para gerar as Applications.
registrar_cluster() {
    local manifesto
    manifesto=$(cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$NOME_DO_AMBIENTE
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    environment: $NOME_DO_AMBIENTE
    uniplus.io/managed: "true"
type: Opaque
stringData:
  name: $NOME_DO_AMBIENTE
  server: https://kubernetes.default.svc
  config: '{"tlsClientConfig":{"insecure":false}}'
YAML
)
    if $DRY_RUN; then
        echo "[DRY-RUN] kubectl apply do Secret de cluster (environment=$NOME_DO_AMBIENTE)"
    else
        printf '%s\n' "$manifesto" | kubectl apply -f -
    fi
}
