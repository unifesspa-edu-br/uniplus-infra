#!/bin/sh
# Roda DENTRO do contêiner descartável do Kafka, pelos scripts de provisionamento (lib-kafka.sh).
# Lê a senha do usuário SCRAM na entrada padrão e a aplica com `kafka-configs`.
#
# A credencial vai num arquivo 0600 do /tmp do contêiner, lido por
# --add-config-file: argumento de processo aparece no `ps` do host, arquivo dentro
# do contêiner não. O arquivo é lido como Java properties, que interpreta escapes e
# bytes não ASCII; por isso o chamador só entrega senha do alfabeto [0-9A-Za-z._~-].
#
# Variáveis: BOOTSTRAP, USUARIO. Pede /tmp/admin.properties (credencial do administrador).
set -eu

umask 077
read -r SENHA_DO_USUARIO
printf 'SCRAM-SHA-512=password=%s\n' "$SENHA_DO_USUARIO" >/tmp/scram.properties
unset SENHA_DO_USUARIO

status=0
/opt/kafka/bin/kafka-configs.sh --bootstrap-server "$BOOTSTRAP" \
    --command-config /tmp/admin.properties --alter \
    --add-config-file /tmp/scram.properties \
    --entity-type users --entity-name "$USUARIO" || status=$?
rm -f /tmp/scram.properties
exit "$status"
