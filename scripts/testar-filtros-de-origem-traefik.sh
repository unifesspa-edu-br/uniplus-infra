#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
chart=platform/traefik
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/admin.yaml" <<'YAML'
middlewares:
  adminInterno:
    enabled: true
    sourceRange: [192.0.2.0/24]
YAML
cat > "$tmp/esperado.yaml" <<'YAML'
---
# Source: traefik/templates/middleware-admin-interno.yaml
# Restringe as rotas de administração à rede institucional/VPN. Nome fixo, para
# as IngressRoutes de outros namespaces referenciarem com
# `namespace: default` (allowCrossNamespace está ligado).
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: uniplus-admin-interno
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: teste
    app.kubernetes.io/version: "v3.6.15"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: uniplus
    app.kubernetes.io/component: traefik
spec:
  ipAllowList:
    sourceRange:
      - 192.0.2.0/24
YAML
helm template teste "$chart" -f "$tmp/admin.yaml" --show-only templates/middleware-admin-interno.yaml > "$tmp/admin-render.yaml"
diff -u "$tmp/esperado.yaml" "$tmp/admin-render.yaml"
helm template teste "$chart" -f "$tmp/admin.yaml" > "$tmp/render.yaml"
[[ $(grep -c '  name: uniplus-admin-interno$' "$tmp/render.yaml") == 1 ]]
if grep -q 'Source: traefik/templates/middleware-filtros-de-origem.yaml' "$tmp/render.yaml"; then exit 1; fi
echo '✓ adminInterno inalterado'

if git rev-parse --verify --quiet 'origin/main^{commit}' > /dev/null; then
  mkdir -p "$tmp/referencia"
  git archive origin/main platform/traefik | tar -x -C "$tmp/referencia"
  chart_ref="$tmp/referencia/$chart"
  if [[ -d "$chart/charts" ]]; then
    cp -a "$chart/charts" "$chart_ref/"
  else
    helm dependency build "$chart_ref"
  fi
  helm template teste "$chart_ref" -f environments/uniplus-prd/values.yaml -f "$tmp/admin.yaml" > "$tmp/referencia.yaml"
  helm template teste "$chart" -f environments/uniplus-prd/values.yaml -f "$tmp/admin.yaml" > "$tmp/atual.yaml"
  diff -u "$tmp/referencia.yaml" "$tmp/atual.yaml"
  echo '✓ renderização completa igual à origin/main'
else
  echo 'Aviso: origin/main não está disponível localmente; comparação da renderização completa ignorada.' >&2
fi

cat > "$tmp/filtros.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: uniplus-vault-interno
      sourceRange: [198.51.100.0/24]
YAML
helm template teste "$chart" -f "$tmp/admin.yaml" -f "$tmp/filtros.yaml" > "$tmp/render.yaml"
grep -q '  name: uniplus-vault-interno$' "$tmp/render.yaml"
grep -q '      - 198.51.100.0/24$' "$tmp/render.yaml"
helm template teste "$chart" -f "$tmp/admin.yaml" -f "$tmp/filtros.yaml" --show-only templates/middleware-admin-interno.yaml > "$tmp/admin-render.yaml"
diff -u "$tmp/esperado.yaml" "$tmp/admin-render.yaml"
echo '✓ novo filtro independente'
cat >> "$tmp/filtros.yaml" <<'YAML'
    - nome: uniplus-outro
      sourceRange: [192.0.2.0/24]
YAML
helm template teste "$chart" -f "$tmp/filtros.yaml" --show-only templates/middleware-filtros-de-origem.yaml > "$tmp/render.yaml"
cat > "$tmp/dois-esperado.yaml" <<'YAML'
---
# Source: traefik/templates/middleware-filtros-de-origem.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: uniplus-vault-interno
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: teste
    app.kubernetes.io/version: "v3.6.15"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: uniplus
    app.kubernetes.io/component: traefik
spec:
  ipAllowList:
    sourceRange:
      - 198.51.100.0/24
---
# Source: traefik/templates/middleware-filtros-de-origem.yaml
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: uniplus-outro
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/instance: teste
    app.kubernetes.io/version: "v3.6.15"
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/part-of: uniplus
    app.kubernetes.io/component: traefik
spec:
  ipAllowList:
    sourceRange:
      - 192.0.2.0/24
YAML
diff -u "$tmp/dois-esperado.yaml" "$tmp/render.yaml"
echo '✓ dois filtros com faixas próprias'

recusa() {
  local descricao=$1 mensagem=$2
  if helm template teste "$chart" -f "$tmp/invalido.yaml" > "$tmp/saida" 2>&1; then
    echo "Falha: $descricao foi aceito" >&2
    exit 1
  fi
  if ! grep -Fq "$mensagem" "$tmp/saida"; then
    cat "$tmp/saida" >&2
    exit 1
  fi
  echo "✓ $descricao"
}
cat > "$tmp/invalido.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: uniplus-repetido
      sourceRange: [192.0.2.0/24]
    - nome: uniplus-repetido
      sourceRange: [192.0.2.0/24]
YAML
recusa 'nome repetido' 'Filtro 1 (uniplus-repetido): os nomes dos filtros não podem se repetir'
for nome in uniplus-admin-interno uniplus-compress uniplus-headers-security; do
  printf 'middlewares:\n  filtrosDeOrigem:\n    - nome: %s\n      sourceRange: [192.0.2.0/24]\n' "$nome" > "$tmp/invalido.yaml"
  recusa "nome reservado $nome" "Filtro 0 ($nome): este nome já é usado por um filtro do próprio chart"
done
cat > "$tmp/invalido.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: vault-interno
      sourceRange: [192.0.2.0/24]
YAML
recusa 'nome sem prefixo' 'Filtro 0 (vault-interno): o nome deve começar com uniplus-'
cat > "$tmp/invalido.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: uniplus-Invalido_
      sourceRange: [192.0.2.0/24]
YAML
recusa 'caracteres inválidos no nome' 'são permitidos letras minúsculas, números e hífen, começando e terminando com letra ou número'

nome_63="uniplus-$(printf 'a%.0s' {1..55})"
nome_64="${nome_63}a"
printf 'middlewares:\n  filtrosDeOrigem:\n    - nome: %s\n      sourceRange: [192.0.2.0/24]\n' "$nome_64" > "$tmp/invalido.yaml"
recusa 'nome com 64 caracteres' 'o nome deve ter no máximo 63 caracteres; tamanho informado: 64'
printf 'middlewares:\n  filtrosDeOrigem:\n    - nome: %s\n      sourceRange: [192.0.2.0/24]\n' "$nome_63" > "$tmp/limite.yaml"
helm template teste "$chart" -f "$tmp/limite.yaml" > "$tmp/render.yaml"
grep -Fq "  name: $nome_63" "$tmp/render.yaml"
echo '✓ nome com 63 caracteres aceito'

cat > "$tmp/invalido.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: uniplus-vazio
      sourceRange: []
YAML
recusa 'faixas vazias' 'Filtro 0 (uniplus-vazio): informe ao menos uma faixa; sem faixas o filtro não liberaria ninguém'
cat > "$tmp/invalido.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: uniplus-invalido
      sourceRange: [192.0.2.300/24]
YAML
recusa 'CIDR inválido' 'Filtro 0 (uniplus-invalido): a faixa 192.0.2.300/24 não é um CIDR IPv4 válido'

cat > "$tmp/invalido.yaml" <<'YAML'
middlewares:
  filtrosDeOrigem:
    - nome: uniplus-ausente
YAML
recusa 'faixas ausentes' 'Filtro 0 (uniplus-ausente): informe ao menos uma faixa; sem faixas o filtro não liberaria ninguém'
for chave in middlewares.enabled traefik.enabled; do
  helm template teste "$chart" -f "$tmp/filtros.yaml" --set "$chave=false" > "$tmp/render.yaml"
  if grep -q 'Source: traefik/templates/middleware-filtros-de-origem.yaml' "$tmp/render.yaml"; then
    echo "Falha: filtros criados com $chave=false" >&2
    exit 1
  fi
done
echo '✓ filtros respeitam as chaves de ativação'
