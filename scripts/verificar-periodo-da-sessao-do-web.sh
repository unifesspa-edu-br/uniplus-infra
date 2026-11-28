#!/usr/bin/env bash
# Confere que oidc.periodoMaximoDaSessaoEmSegundos de cada aplicação web, como o
# chart o renderiza, é igual ao ssoSessionMaxLifespan do realm exportado.
set -euo pipefail

raiz=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
realm="$raiz/apps/keycloak-replica/files/uniplus-realm.json"

esperado=$(grep -oE '"ssoSessionMaxLifespan": *[0-9]+' "$realm" | grep -oE '[0-9]+$' || true)
[[ -n "$esperado" ]] || { echo "✗ ssoSessionMaxLifespan não encontrado em $realm" >&2; exit 1; }

renderizado=$(helm template web "$raiz/apps/uniplus-web" -f "$raiz/apps/uniplus-web/values.yaml" \
        -f "$raiz/environments/uniplus-prd/values.yaml" \
    | grep -oE '"periodoMaximoDaSessaoEmSegundos": *[0-9]+' || true)
[[ -n "$renderizado" ]] || { echo "✗ nenhum runtime-config traz periodoMaximoDaSessaoEmSegundos" >&2; exit 1; }

falhou=0
while IFS= read -r linha; do
    valor=${linha##*: }
    if [[ "$valor" != "$esperado" ]]; then
        echo "✗ periodoMaximoDaSessaoEmSegundos=$valor, o realm tem $esperado" >&2
        falhou=1
    fi
done <<< "$renderizado"

((falhou == 0)) || exit 1
echo "✓ período máximo da sessão dos $(wc -l <<< "$renderizado") aplicativos web igual ao do realm ($esperado s)"
