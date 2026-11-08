#!/usr/bin/env bash
# Renova o certificado curinga da instituição numa das duas VMs: confere o novo
# par, instala em /etc/uniplus/tls e reinicia cada serviço que o usa. Rodar nas
# duas VMs, uma de cada vez, com o mesmo par.
#
# Uso:
#   ./renovar-certificado.sh --vm=app|infra --cert=bundle.crt --key=chave.key [--dry-run]
#
# Na VM de aplicação, atualiza o Secret TLS nos namespaces (o Traefik recarrega
# sozinho), manda o Vault reler o certificado do listener (SIGHUP, sem reiniciar: um
# reinício o deixaria selado) e confere o certificado que ele passa a servir, regrava
# no Vault o certificado do KES e o CA do Kafka e, depois de os ExternalSecrets
# sincronizarem, reinicia o KES. Na VM de infraestrutura, reinstala o
# par para cada serviço (inclusive o certificado do KES que o MinIO confia) e reinicia
# as unidades. Fazer a VM de aplicação primeiro.
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
    [[ -z "$NOME_DO_VAULT" ]] || openssl x509 -in "$NOVO_CERT" -noout -checkhost "$NOME_DO_VAULT" | grep -q 'does match' \
        || { log_error "O certificado não cobre $NOME_DO_VAULT."; exit 1; }
}

guardar_e_instalar() {
    run "sudo install -d -m 750 $TLS_DIR/anterior"
    run "sudo cp -p $TLS_KEY $TLS_BUNDLE $TLS_DIR/anterior/ 2>/dev/null || true"
    run "sudo install -m 600 $NOVA_CHAVE $TLS_KEY"
    run "sudo install -m 644 $NOVO_CERT $TLS_BUNDLE"
}

# Espera todos os ExternalSecrets do namespace terem sincronizado depois de `inicio`
# (época em segundos) e ficado prontos; sem isso, o reinício leria o Secret velho.
esperar_externalsecrets() {
    local ns="$1" inicio="$2" _ pendentes
    for _ in $(seq 1 36); do
        pendentes=$(kubectl -n "$ns" get externalsecret -o json | INICIO="$inicio" python3 -c '
import datetime, json, os, sys
inicio = int(os.environ["INICIO"])
pendentes = 0
for es in json.load(sys.stdin)["items"]:
    st = es.get("status", {})
    ok = any(c["type"] == "Ready" and c["status"] == "True" for c in st.get("conditions", []))
    t = st.get("refreshTime")
    atualizado = t and datetime.datetime.fromisoformat(t.replace("Z", "+00:00")).timestamp() >= inicio
    pendentes += 0 if ok and atualizado else 1
print(pendentes)')
        [[ "$pendentes" == 0 ]] && return 0
        sleep 5
    done
    log_error "ExternalSecrets de $ns não sincronizaram em 3 minutos."
    exit 1
}

# Impressão digital SHA-256 do primeiro certificado de um PEM (o do servidor).
impressao_do_certificado() {
    openssl x509 -noout -fingerprint -sha256
}

# O Vault lê o par TLS do Secret montado no pod. Espera o kubelet projetar o Secret
# novo, manda o Vault reler o listener (SIGHUP) e repete por pod.
recarregar_certificado_do_vault() {
    local pod esperado atual _
    esperado=$(impressao_do_certificado <"$TLS_BUNDLE")
    for pod in $(kubectl -n "$VAULT_NAMESPACE" get pods \
        -l app.kubernetes.io/name=vault,component=server -o name); do
        for _ in $(seq 1 24); do
            atual=$(kubectl -n "$VAULT_NAMESPACE" exec "$pod" -c vault -- \
                cat "/vault/userconfig/$TLS_SECRET_NAME/tls.crt" | impressao_do_certificado) || atual=""
            [[ "$atual" == "$esperado" ]] && break
            sleep 5
        done
        [[ "$atual" == "$esperado" ]] || { log_error "$pod não recebeu o certificado novo em 2 minutos."; exit 1; }
        kubectl -n "$VAULT_NAMESPACE" exec "$pod" -c vault -- sh -c 'kill -HUP "$(pidof vault)"'
        log_success "$pod releu o certificado do listener."
    done
}

# Confere, pelo port-forward já aberto, que o Vault serve o certificado novo.
conferir_certificado_do_vault() {
    local servido esperado
    esperado=$(impressao_do_certificado <"$TLS_BUNDLE")
    servido=$(openssl s_client -connect "127.0.0.1:$VAULT_LOCAL_PORT" -servername "$NOME_DO_VAULT" \
        </dev/null 2>/dev/null | impressao_do_certificado) || servido=""
    [[ "$servido" == "$esperado" ]] || { log_error "O Vault ainda serve outro certificado ($servido)."; exit 1; }
    log_success "O Vault serve o certificado novo."
}

# Regrava no Vault o que carrega o certificado: o do servidor KES (plataforma), o CA
# do Kafka (uniplus) e o ca_cert do administrador do Kafka, que existe no KV do
# Uni+ e no de plataforma. No KV v2 cada gravação troca o conteúdo inteiro, então
# o usuário e a senha do administrador são relidos de cada KV.
atualizar_vault() {
    local sistema usuario senha
    vault_put plataforma/kes/server "cert=$(cat "$TLS_BUNDLE")" "key=$(sudo cat "$TLS_KEY")"
    vault_put uniplus/kafka/ca "ca_cert=$(cat "$TLS_BUNDLE")"
    for sistema in uniplus plataforma; do
        usuario=$(vault_get "$sistema/kafka/admin" username) \
            || { log_error "Não foi possível ler o usuário de $sistema/kafka/admin."; exit 1; }
        senha=$(vault_get "$sistema/kafka/admin" password) \
            || { log_error "Não foi possível ler a senha de $sistema/kafka/admin."; exit 1; }
        vault_put "$sistema/kafka/admin" "username=$usuario" "password=$senha" "ca_cert=$(cat "$TLS_BUNDLE")"
    done
}

renovar_app() {
    export KUBECONFIG="$HOME/.kube/config"
    publicar_segredo_tls
    if $DRY_RUN; then
        echo "[DRY-RUN] mandaria o Vault reler o certificado (SIGHUP em cada pod) e conferiria o certificado servido"
        echo "[DRY-RUN] regravaria no Vault (port-forward local) plataforma/kes/server, uniplus/kafka/ca e kafka/admin (uniplus e plataforma)"
        echo "[DRY-RUN] esperaria os ExternalSecrets do KES sincronizarem e reiniciaria o KES"
        return 0
    fi
    # Vazio de propósito: o Vault é alcançado por port-forward neste host, sem
    # depender da lista de IPs liberados no Traefik.
    export VAULT_URL=""
    # shellcheck source=lib-provisionar.sh
    source "$SCRIPT_DIR/lib-provisionar.sh"
    recarregar_certificado_do_vault
    preparar_provisionamento
    conferir_certificado_do_vault
    local inicio
    inicio=$(date +%s)
    atualizar_vault
    kubectl -n kes annotate externalsecret --all "force-sync=$inicio" --overwrite
    esperar_externalsecrets kes "$inicio"
    kubectl -n kes rollout restart deployment
    kubectl -n kes rollout status deployment --timeout=180s
}

renovar_infra() {
    instalar_par_tls "$DATA_BASE/postgres/tls" 999
    instalar_par_tls "$DATA_BASE/redis/tls" 999
    instalar_par_tls "$DATA_BASE/minio/tls" 1000
    instalar_par_tls "$DATA_BASE/rabbitmq/tls" 100
    # O MinIO confia no KES por este arquivo; o KES serve o mesmo certificado.
    run "sudo install -m 644 $TLS_BUNDLE /etc/uniplus-minio-kes/kes.crt"
    run "sudo install -m 644 -o 1000 -g 1000 $TLS_BUNDLE $KAFKA_CERTS_DIR/server.crt"
    run "sudo install -m 644 -o 1000 -g 1000 $TLS_BUNDLE $KAFKA_CERTS_DIR/ca.crt"
    # O Kafka só lê chave PKCS#8; a do domínio pode ser PKCS#1.
    run "(umask 077; sudo openssl pkcs8 -topk8 -nocrypt -in $TLS_KEY | sudo tee $KAFKA_CERTS_DIR/server.key >/dev/null)"
    run "sudo chown 1000:1000 $KAFKA_CERTS_DIR/server.key && sudo chmod 600 $KAFKA_CERTS_DIR/server.key"
    run "sudo sh -c 'cat $KAFKA_CERTS_DIR/server.crt $KAFKA_CERTS_DIR/server.key > $KAFKA_CERTS_DIR/server.pem' && sudo chown 1000:1000 $KAFKA_CERTS_DIR/server.pem && sudo chmod 600 $KAFKA_CERTS_DIR/server.pem"
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
