#!/usr/bin/env bash
# Grava no Vault de produção os segredos que nascem na VM de infraestrutura:
# Redis, usuário raiz do MinIO, administradores do RabbitMQ e do Kafka e segredos
# das interfaces de administração. As APIs cifram pelo Transit do Vault (criado por
# configurar-vault.sh), então não há chave de cifra a semear. Só grava o que ainda não existe; nunca troca segredo vivo.
#
# Cada sistema tem o próprio KV (uniplus-<amb>, geo-<amb>, plataforma-<amb>): o
# segredo compartilhado é gravado no KV de cada sistema que o consome (mapa em
# docs/vault-caminhos.md). Não grava o SMTP nem os clients do Keycloak: vêm de
# fora (ver docs/RUNBOOKS.md, seção de produção).
#
# Uso: [VAULT_URL=...] ./semear-vault.sh [--dry-run]
# Rodar na VM de infraestrutura, depois de configurar-vault.sh, com o Vault aberto. A
# inicialização do Vault (Shamir 5/3) é manual e fica fora dos scripts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-provisionar.sh
source "$SCRIPT_DIR/lib-provisionar.sh"

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

semear_servicos_de_dados() {
    garantir_compartilhado "uniplus geo plataforma" redis \
        "username=default" "password=$(ler_credencial "$DATA_BASE/redis/.bootstrap-creds" default_pw)"
    garantir_compartilhado "uniplus plataforma" minio/root \
        "username=$(ler_credencial "$DATA_BASE/minio/.bootstrap-creds" root_user)" \
        "password=$(ler_credencial "$DATA_BASE/minio/.bootstrap-creds" root_pw)"
    garantir_no_vault plataforma/rabbitmq/admin \
        "username=rabbitmq-admin" "password=$(ler_credencial "$DATA_BASE/rabbitmq/.bootstrap-creds" admin_pw)"
}

# Credencial do administrador do Kafka e o CA que as aplicações usam para validar o
# broker (o bundle do domínio, com a raiz).
semear_kafka() {
    garantir_compartilhado "uniplus plataforma" kafka/admin \
        "username=admin" \
        "password=$(ler_credencial "$DATA_BASE/kafka/.bootstrap-creds" admin_pw)" \
        "ca_cert=$(sudo cat /etc/uniplus-kafka/certs/ca.crt)"
}

# Segredos das interfaces de administração. A senha do Redis UI fica no Vault
# (`password`) para quem opera consultar; o hash vai em `htpasswd`.
semear_interfaces() {
    garantir_no_vault plataforma/kafka-ui/jwt "signing_secret=$(openssl rand -hex 32)"
    if vault_existe plataforma/redis-ui/basic-auth; then
        log_success "plataforma/redis-ui/basic-auth já existe no Vault; preservado."
        return 0
    fi
    local senha hash
    senha=$(openssl rand -hex 16)
    hash=$(printf '%s' "$senha" | openssl passwd -apr1 -stdin)
    vault_put plataforma/redis-ui/basic-auth \
        "username=redis-ui" "password=$senha" "htpasswd=redis-ui:$hash"
    log_success "plataforma/redis-ui/basic-auth gravado no Vault."
}

analisar_argumentos "$@"
exigir_usuario_comum
if $DRY_RUN; then
    echo "[DRY-RUN] gravaria no Vault, se ausentes: redis (uniplus, geo, plataforma), minio/root e kafka/admin (uniplus, plataforma),"
    echo "[DRY-RUN]   plataforma/rabbitmq/admin, plataforma/kafka-ui/jwt, plataforma/redis-ui/basic-auth"
    exit 0
fi
preparar_provisionamento
semear_servicos_de_dados
semear_kafka
semear_interfaces
