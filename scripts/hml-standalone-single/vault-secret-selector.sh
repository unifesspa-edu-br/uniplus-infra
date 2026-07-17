#!/usr/bin/env bash
# Lista campos de segredos KV v2 custodiados no Vault do HML e exibe somente
# o valor que o operador selecionar e confirmar. Executar na VM HML.
set -euo pipefail

KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-platform-vault-in-cluster-0}"
VAULT_PORT="${VAULT_PORT:-18201}"
VAULT_ADDR="http://127.0.0.1:${VAULT_PORT}"
VAULT_ROOT="secret/standalone"

declare -a secret_fields=()
tmpdir=""
pf_pid=""

usage() {
    cat <<'EOF'
Uso: vault-secret-selector.sh [--list]

Lista campos dos segredos sob secret/standalone no Vault do HML. No modo
interativo, o operador seleciona e confirma antes de o valor ser exibido.

Pré-requisitos: ROOT_TOKEN no ambiente, kubectl, curl e jq. O script deve
rodar na própria VM HML; ele usa um port-forward temporário para o pod Vault.

Opções:
  --list  Lista apenas os caminhos/campos, sem revelar valores.
  -h, --help  Exibe esta ajuda.
EOF
}

cleanup() {
    [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true
    [[ -n "$tmpdir" ]] && shred -u "$tmpdir/vault.curl" 2>/dev/null || true
    [[ -n "$tmpdir" ]] && rm -rf "$tmpdir"
    unset ROOT_TOKEN
}
trap cleanup EXIT

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Comando obrigatório ausente: $1" >&2
        exit 1
    }
}

load_root_token() {
    if [[ -z "${ROOT_TOKEN:-}" ]]; then
        # SSH não abre um shell interativo e ~/.bashrc pode retornar cedo.
        # O token é carregado somente para a memória deste processo.
        ROOT_TOKEN=$(bash -ic 'printf "%s" "${ROOT_TOKEN:-}"' 2>/dev/null || true)
    fi

    [[ -n "${ROOT_TOKEN:-}" ]] || {
        echo "ROOT_TOKEN não foi encontrado. Carregue ~/.bashrc antes de executar." >&2
        exit 1
    }
}

start_vault_port_forward() {
    (
        sudo sh -c 'KUBECONFIG="$1" exec kubectl -n "$2" port-forward "pod/$3" "$4":8200' \
            sh "$KUBECONFIG_PATH" "$VAULT_NAMESPACE" "$VAULT_POD" "$VAULT_PORT"
    ) >"$tmpdir/vault-port-forward.log" 2>&1 &
    pf_pid=$!

    for _ in $(seq 1 30); do
        if curl -fsS --config "$tmpdir/vault.curl" "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
            return
        fi
        sleep 1
    done

    echo "Não foi possível alcançar o Vault por port-forward." >&2
    sed -n '1,80p' "$tmpdir/vault-port-forward.log" >&2 || true
    exit 1
}

vault_list() {
    local path="$1"
    local api_path

    api_path="${path#secret/}"
    curl -fsS --config "$tmpdir/vault.curl" -X LIST \
        "$VAULT_ADDR/v1/secret/metadata/$api_path"
}

vault_read() {
    local path="$1"
    local api_path

    api_path="${path#secret/}"
    curl -fsS --config "$tmpdir/vault.curl" \
        "$VAULT_ADDR/v1/secret/data/$api_path"
}

collect_secret_fields() {
    local path="$1"
    local child
    local field
    local listing
    local secret_json

    listing=$(vault_list "$path") || {
        echo "Não foi possível listar $path no Vault." >&2
        return 1
    }

    while IFS= read -r child; do
        if [[ "$child" == */ ]]; then
            collect_secret_fields "$path/${child%/}"
            continue
        fi

        secret_json=$(vault_read "$path/$child") || {
            echo "Não foi possível ler os campos de $path/$child." >&2
            return 1
        }
        while IFS= read -r field; do
            secret_fields+=("$path/$child"$'\t'"$field")
        done < <(jq -er '.data.data | keys[]' <<<"$secret_json")
        unset secret_json
    done < <(jq -er '.data.keys[]' <<<"$listing")
}

print_available_fields() {
    local entry
    local label

    for entry in "${secret_fields[@]}"; do
        label="${entry/$'\t'/\/}"
        printf '%s\n' "$label"
    done
}

select_secret_field() {
    local choice
    local index
    local entry
    local label
    local path
    local field
    local confirm

    echo ""
    echo "Campos disponíveis (nenhum valor foi exibido):"
    for index in "${!secret_fields[@]}"; do
        entry="${secret_fields[$index]}"
        label="${entry/$'\t'/\/}"
        printf '%3d) %s\n' "$((index + 1))" "$label"
    done

    while true; do
        read -r -p "Selecione um campo (0 para sair): " choice
        [[ "$choice" =~ ^[0-9]+$ ]] || {
            echo "Informe um número válido." >&2
            continue
        }

        index=$((10#$choice))
        ((index == 0)) && return 0
        if ((index < 1 || index > ${#secret_fields[@]})); then
            echo "Opção fora do intervalo." >&2
            continue
        fi
        break
    done

    entry="${secret_fields[$((index - 1))]}"
    path="${entry%%$'\t'*}"
    field="${entry#*$'\t'}"
    label="$path/$field"

    read -r -p "Exibir o valor de $label no console? [s/N] " confirm
    [[ "$confirm" =~ ^[sS]$ ]] || {
        echo "Operação cancelada; nenhum valor foi exibido."
        return 0
    }

    vault_read "$path" | jq -er --arg field "$field" '
        .data.data[$field]
        | if . == null then error("campo ausente")
          elif type == "string" then .
          else tostring
          end
    '
}

mode="interactive"
case "${1:-}" in
    "") ;;
    --list) mode="list" ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

if [[ "$mode" == "interactive" ]] && [[ ! -t 0 || ! -t 1 ]]; then
    echo "O modo interativo exige um terminal. Use --list para listar apenas os campos." >&2
    exit 1
fi

for binary in kubectl curl jq sudo; do
    require_command "$binary"
done
load_root_token

tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
printf 'header = "X-Vault-Token: %s"\n' "$ROOT_TOKEN" > "$tmpdir/vault.curl"
chmod 600 "$tmpdir/vault.curl"

start_vault_port_forward
collect_secret_fields "$VAULT_ROOT"

((${#secret_fields[@]} > 0)) || {
    echo "Nenhum campo foi encontrado em $VAULT_ROOT." >&2
    exit 1
}

if [[ "$mode" == "list" ]]; then
    print_available_fields
    exit 0
fi

select_secret_field
