#!/usr/bin/env bash
# Renova o certificado curinga da instituição numa das duas VMs: confere o novo
# par, instala em /etc/uniplus/tls e reinicia cada serviço que o usa. Rodar nas
# duas VMs, uma de cada vez, com o mesmo par.
#
# Uso:
#   ./renovar-certificado.sh --vm=app|infra --cert=bundle.crt --key=chave.key [--dry-run]
#
# Na VM de aplicação, atualiza o Secret TLS nos namespaces (o Traefik recarrega
# sozinho) e reinicia o KES depois de regravar o certificado dele no Vault. Na
# VM de infraestrutura, reinstala o par para cada serviço e reinicia as unidades.
# O par antigo é guardado em /etc/uniplus/tls/anterior.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-app.sh
source "$SCRIPT_DIR/lib-app.sh"

VM=""
NOVO_CERT=""
NOVA_CHAVE=""
KAFKA_CERTS_DIR="/etc/uniplus-kafka/certs"
UNIDADES_INFRA=(uniplus-postgres uniplus-redis uniplus-minio uniplus-kafka uniplus-rabbitmq)

mostrar_uso() {
    echo "Uso: $0 --vm=app|infra --cert=bundle.crt --key=chave.key [--dry-run]"
}

analisar_renovacao() {
    local resto=() arg
    for arg in "$@"; do
        case "$arg" in
            --vm=*) VM="${arg#--vm=}" ;;
            --cert=*) NOVO_CERT="${arg#--cert=}" ;;
            --key=*) NOVA_CHAVE="${arg#--key=}" ;;
            *) resto+=("$arg") ;;
        esac
    done
    analisar_argumentos "${resto[@]}"
    [[ "$VM" == app || "$VM" == infra ]] && [[ -n "$NOVO_CERT" && -n "$NOVA_CHAVE" ]] || {
        mostrar_uso >&2
        exit 2
    }
}

# O par novo precisa casar, estar no prazo e cobrir o nome da VM de infraestrutura.
validar_par() {
    $DRY_RUN && return 0
    local pub_cert pub_chave
    pub_cert=$(openssl x509 -in "$NOVO_CERT" -noout -pubkey | sha256sum)
    pub_chave=$(openssl pkey -in "$NOVA_CHAVE" -pubout | sha256sum)
    [[ "$pub_cert" == "$pub_chave" ]] || { log_error "A chave não corresponde ao certificado."; exit 1; }
    openssl x509 -in "$NOVO_CERT" -noout -checkend 86400 >/dev/null \
        || { log_error "O certificado expira em menos de um dia."; exit 1; }
    openssl x509 -in "$NOVO_CERT" -noout -checkhost "$INFRA_FQDN" | grep -q 'does match' \
        || { log_error "O certificado não cobre $INFRA_FQDN."; exit 1; }
}

guardar_e_instalar() {
    run "sudo install -d -m 750 $TLS_DIR/anterior"
    run "sudo cp -p $TLS_KEY $TLS_BUNDLE $TLS_DIR/anterior/ 2>/dev/null || true"
    run "sudo install -m 600 $NOVA_CHAVE $TLS_KEY"
    run "sudo install -m 644 $NOVO_CERT $TLS_BUNDLE"
}

renovar_app() {
    export KUBECONFIG="$HOME/.kube/config"
    publicar_segredo_tls
    if $DRY_RUN; then
        echo "[DRY-RUN] regravaria secret/standalone/kes/server no Vault e reiniciaria o deployment do KES"
        return 0
    fi
    # shellcheck source=lib-provisionar.sh
    source "$SCRIPT_DIR/lib-provisionar.sh"
    export VAULT_URL="${VAULT_URL:-https://uniplus-vault.unifesspa.edu.br}"
    preparar_provisionamento
    vault_put standalone/kes/server "cert=$(cat "$TLS_BUNDLE")" "key=$(sudo cat "$TLS_KEY")"
    kubectl -n kes annotate externalsecret --all "force-sync=$(date +%s)" --overwrite
    kubectl -n kes rollout restart deployment
    kubectl -n kes rollout status deployment --timeout=180s
}

renovar_infra() {
    instalar_par_tls "$DATA_BASE/postgres/tls" 999
    instalar_par_tls "$DATA_BASE/redis/tls" 999
    instalar_par_tls "$DATA_BASE/minio/tls" 1000
    instalar_par_tls "$DATA_BASE/rabbitmq/tls" 100
    run "sudo install -m 644 -o 1000 -g 1000 $TLS_BUNDLE $KAFKA_CERTS_DIR/server.crt"
    run "sudo install -m 644 -o 1000 -g 1000 $TLS_BUNDLE $KAFKA_CERTS_DIR/ca.crt"
    run "sudo install -m 600 -o 1000 -g 1000 $TLS_KEY $KAFKA_CERTS_DIR/server.key"
    run "cat $KAFKA_CERTS_DIR/server.crt $KAFKA_CERTS_DIR/server.key | sudo tee $KAFKA_CERTS_DIR/server.pem >/dev/null"
    run "sudo chown 1000:1000 $KAFKA_CERTS_DIR/server.pem && sudo chmod 600 $KAFKA_CERTS_DIR/server.pem"
    reiniciar_unidades "${UNIDADES_INFRA[@]}"
}

analisar_renovacao "$@"
exigir_usuario_comum
validar_par
guardar_e_instalar
if [[ "$VM" == app ]]; then
    renovar_app
else
    renovar_infra
fi
log_success "Certificado renovado na VM $VM."
