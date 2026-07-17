#!/usr/bin/env bash
# HML usa a mesma topologia single-node validada no lab. O wrapper mantém o
# ponto de entrada no diretório HML e evita duplicar a rotina idempotente.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/../lab-standalone-single/setup-minio.sh" "$@"
