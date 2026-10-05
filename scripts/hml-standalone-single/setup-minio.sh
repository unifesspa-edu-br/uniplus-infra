#!/usr/bin/env bash
# HML usa a mesma topologia single-node validada no lab. O wrapper mantém o
# ponto de entrada no diretório HML e evita duplicar a rotina idempotente.
#
# A única diferença é a política do acervo público (ADR-0132 do uniplus-api):
# em HML a leitura anônima só vale para quem chega pela borda. A variante
# versionada em minio/acervo-publico.policy.json restringe `aws:SourceIp` à
# rede de pods do cluster (10.42.0.0/16, default do k3s), de onde o Traefik
# alcança a porta de dados — e a rota do acervo remove os cabeçalhos de origem
# encaminhada para que o MinIO avalie o endereço da conexão, não o do cliente.
# O GET anônimo feito direto em <host>:9000, de fora da rede de pods, é recusado.
# Ver docs/RUNBOOKS.md §21.8 para o alcance e o limite dessa condição.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ACERVO_PUBLICO_POLICY_FILE="${ACERVO_PUBLICO_POLICY_FILE:-$SCRIPT_DIR/minio/acervo-publico.policy.json}"
exec "$SCRIPT_DIR/../lab-standalone-single/setup-minio.sh" "$@"
