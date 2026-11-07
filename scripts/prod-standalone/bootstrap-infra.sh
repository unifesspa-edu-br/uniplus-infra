#!/usr/bin/env bash
# Bootstrap da VM de infraestrutura de produção (uniplus-prod-infra): PostgreSQL
# com PostGIS, Redis, MinIO, Kafka e RabbitMQ em containers Docker gerenciados
# por systemd, todos só com TLS e alcançáveis apenas pela VM de aplicação.
#
# Uso:
#   ./bootstrap-infra.sh [--dry-run]
#
# Pré-requisitos: Ubuntu 24.04, usuário com sudo sem senha (não root) e o par do
# certificado curinga em /etc/uniplus/tls (unifesspa.edu.br.key e
# unifesspa.edu.br-bundle.crt), instalado por quem opera a VM. Os serviços são
# acessados pelo nome INFRA_FQDN, que o certificado precisa cobrir.
#
# Idempotente. Cada serviço é configurado pelos scripts de laboratório e de
# homologação, com os parâmetros de TLS; o que muda em produção está só nas
# variáveis passadas a eles.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"
# shellcheck source=lib-infra-postgres.sh
source "$SCRIPT_DIR/lib-infra-postgres.sh"
# shellcheck source=lib-infra-rabbitmq.sh
source "$SCRIPT_DIR/lib-infra-rabbitmq.sh"
# shellcheck source=lib-infra-firewall.sh
source "$SCRIPT_DIR/lib-infra-firewall.sh"

LAB_DIR="$SCRIPT_DIR/../lab-standalone-single"
HML_DIR="$SCRIPT_DIR/../hml-standalone-single"
REDIS_UID=999
MINIO_UID=1000
KAFKA_UID=1000

mostrar_uso() {
    echo "Uso: $0 [--dry-run]"
}

# Executa um script de serviço repassando --dry-run.
chamar() {
    local script="$1"
    shift
    if $DRY_RUN; then
        "$script" --dry-run "$@"
    else
        "$script" "$@"
    fi
}

step_redis() {
    instalar_par_tls "$DATA_BASE/redis/tls" "$REDIS_UID"
    DATA_HOST_IP="$INFRA_IP" REDIS_TLS_DIR="$DATA_BASE/redis/tls" REDIS_TLS_HOST="$INFRA_FQDN" \
        chamar "$LAB_DIR/setup-redis.sh"
}

step_minio() {
    # Escrito por provisionar-arquivos-candidato.sh depois que o KES existe; o
    # MinIO só o recebe nas execuções seguintes deste bootstrap.
    if sudo test -f /etc/uniplus-minio-kes.env; then
        export MINIO_EXTRA_ENV_FILE=/etc/uniplus-minio-kes.env
        export MINIO_EXTRA_MOUNT_DIR=/etc/uniplus-minio-kes
    fi
    instalar_par_tls "$DATA_BASE/minio/tls" "$MINIO_UID"
    DATA_HOST_IP="$INFRA_IP" MINIO_TLS_DIR="$DATA_BASE/minio/tls" MINIO_PUBLIC_HOST="$INFRA_FQDN" \
        ACERVO_PUBLICO_POLICY_FILE="$SCRIPT_DIR/minio/acervo-publico.policy.json" \
        chamar "$LAB_DIR/setup-minio.sh"
}

step_kafka() {
    instalar_par_tls "$DATA_BASE/kafka/tls" "$KAFKA_UID" server.crt server.key
    DATA_HOST_IP="$INFRA_IP" KAFKA_PUBLIC_HOST="$INFRA_FQDN" \
        KAFKA_TLS_CERT="$DATA_BASE/kafka/tls/server.crt" KAFKA_TLS_KEY="$DATA_BASE/kafka/tls/server.key" \
        KAFKA_TLS_CA="$DATA_BASE/kafka/tls/server.crt" \
        chamar "$HML_DIR/setup-kafka.sh"
}

resumo() {
    cat <<RESUMO

Infraestrutura configurada. Próximos passos:
  1. Na VM de aplicação: ./bootstrap-app.sh, depois inicializar e abrir o Vault.
  2. Aqui: VAULT_URL=https://uniplus-vault.unifesspa.edu.br ./semear-vault.sh
  3. Aqui: ./provisionar-bancos.sh e ./provisionar-rabbitmq.sh
Portas abertas só para ${APP_IP}: ${PORTAS_INFRA[*]}.
RESUMO
}

analisar_argumentos "$@"
exigir_usuario_comum
exigir_par_tls
garantir_docker
step_postgres
step_redis
step_minio
step_kafka
step_rabbitmq
step_firewall
resumo
