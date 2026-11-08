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
# Idempotente. Cada serviço é instalado pelo respectivo instalar-*.sh, com os
# parâmetros de TLS passados por variável. O ambiente (AMBIENTE=prd, o padrão, ou
# hml) vem de lib-comum.sh.
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
        chamar "$SCRIPT_DIR/instalar-redis.sh"
}

step_minio() {
    # O ambiente do KES, escrito por provisionar-arquivos-candidato.sh depois que
    # o KES existe, é incluído por instalar-minio.sh nas execuções seguintes.
    instalar_par_tls "$DATA_BASE/minio/tls" "$MINIO_UID"
    DATA_HOST_IP="$INFRA_IP" MINIO_TLS_DIR="$DATA_BASE/minio/tls" MINIO_PUBLIC_HOST="$INFRA_FQDN" \
        ACERVO_PUBLICO_POLICY_FILE="$SCRIPT_DIR/minio/acervo-publico.policy.json" \
        chamar "$SCRIPT_DIR/instalar-minio.sh"
}

step_kafka() {
    instalar_par_tls "$DATA_BASE/kafka/tls" "$KAFKA_UID" server.crt server.key
    DATA_HOST_IP="$INFRA_IP" KAFKA_PUBLIC_HOST="$INFRA_FQDN" \
        KAFKA_TLS_CERT="$DATA_BASE/kafka/tls/server.crt" KAFKA_TLS_KEY="$DATA_BASE/kafka/tls/server.key" \
        KAFKA_TLS_CA="$DATA_BASE/kafka/tls/server.crt" \
        chamar "$SCRIPT_DIR/instalar-kafka.sh"
}

resumo() {
    cat <<RESUMO

Infraestrutura configurada. Próximos passos:
  1. Na VM de aplicação: ./bootstrap-app.sh, abrir o Vault e rodar configurar-vault.sh.
  2. Aqui, com o Vault aberto: ./semear-vault.sh, ./provisionar-bancos.sh,
     ./provisionar-kafka.sh, ./provisionar-verificacao.sh e ./provisionar-rabbitmq.sh.
Portas abertas só para ${APP_IP}: ${PORTAS_INFRA[*]}.
RESUMO
}

analisar_argumentos "$@"
exigir_usuario_comum
desligar_swap
exigir_par_tls
garantir_docker
step_postgres
step_redis
step_minio
step_kafka
step_rabbitmq
step_firewall
resumo
