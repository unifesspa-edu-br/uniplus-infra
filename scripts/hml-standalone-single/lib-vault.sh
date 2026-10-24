#!/usr/bin/env bash
# Funções de acesso ao Vault de HML por port-forward, para os scripts de
# provisionamento. É carregado com `source`, nunca executado.
#
# O ROOT_TOKEN só existe em memória: vem do ambiente ou de ~/.bashrc, e passa ao
# curl por arquivo de configuração 0600 no tmpdir, nunca por argv.
#
# Depois de `vault_conectar`, ficam disponíveis:
#   vault_conectar <tmpdir>              abre o port-forward (tmpdir 0700, do chamador)
#   vault_get <caminho> <propriedade>    imprime o valor; sai com 1 se o segredo
#                                        não existe e com 2 em qualquer outro erro
#   vault_existe <caminho>               0 se o segredo existe, 1 se não; aborta o
#                                        script em qualquer outro erro
#   vault_put <caminho> <chave=valor>... grava (KV v2); caminho sem o mount `secret`
#   vault_api <método> <caminho> [json]  chamada crua em /v1/<caminho> (ver abaixo)
#
# Não faz `set -e`/`trap` próprios: o script que o carrega cria o tmpdir e chama
# `vault_desconectar` no seu trap de saída.

VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-platform-vault-in-cluster-0}"
VAULT_LOCAL_PORT="${VAULT_LOCAL_PORT:-18200}"
VAULT_ADDR="http://127.0.0.1:${VAULT_LOCAL_PORT}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
_vault_pf_pid=""
_vault_tmp=""

vault_conectar() {
    _vault_tmp="${1:?vault_conectar exige o diretório temporário (0700)}"
    local binary
    for binary in kubectl curl python3 openssl; do
        command -v "$binary" >/dev/null || {
            echo "Comando obrigatório ausente: $binary" >&2
            return 1
        }
    done

    if [[ -z "${ROOT_TOKEN:-}" ]]; then
        # SSH não abre shell interativo e o ~/.bashrc retorna cedo nesse caso.
        ROOT_TOKEN=$(bash -ic 'printf "%s" "${ROOT_TOKEN:-}"' 2>/dev/null)
    fi
    [[ -n "${ROOT_TOKEN:-}" ]] || {
        echo "ROOT_TOKEN não foi encontrado após carregar ~/.bashrc." >&2
        return 1
    }

    (
        sudo sh -c 'KUBECONFIG="$1" exec kubectl -n "$2" port-forward "pod/$3" "$4:8200"' \
            sh "$KUBECONFIG_PATH" "$VAULT_NAMESPACE" "$VAULT_POD" "$VAULT_LOCAL_PORT"
    ) >"$_vault_tmp/vault-port-forward.log" 2>&1 &
    _vault_pf_pid=$!

    local _
    for _ in $(seq 1 30); do
        curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null || {
        echo "Vault inalcançável (selado ou sem port-forward). Ver $_vault_tmp/vault-port-forward.log." >&2
        return 1
    }

    VAULT_CURL_CONFIG="$_vault_tmp/vault.curl"
    printf 'header = "X-Vault-Token: %s"\n' "$ROOT_TOKEN" >"$VAULT_CURL_CONFIG"
    chmod 600 "$VAULT_CURL_CONFIG"
}

vault_desconectar() {
    # O port-forward roda sob sudo (processo de root, filho do sudo): matar o PID
    # do subshell não o alcança. Mata pelo comando exato; se já não existe, não há
    # o que matar, e qualquer outra falha do pkill aparece.
    if [[ -n "$_vault_pf_pid" ]]; then
        local padrao="kubectl -n $VAULT_NAMESPACE port-forward pod/$VAULT_POD $VAULT_LOCAL_PORT:8200"
        if sudo pgrep -f -- "$padrao" >/dev/null; then
            sudo pkill -f -- "$padrao"
        fi
    fi
    unset ROOT_TOKEN
}

# vault_api <método> <caminho> [json]: devolve o código HTTP em VAULT_HTTP_STATUS e
# deixa o corpo em VAULT_BODY_FILE. Não imprime nada e não falha em 4xx: quem chama
# decide. (Sem subshell, para que as duas variáveis cheguem a quem chama.)
vault_api() {
    local method="$1" path="$2" body="${3:-}"
    local out="$_vault_tmp/vault-resposta.json"
    VAULT_BODY_FILE="$out"
    if [[ -n "$body" ]]; then
        VAULT_HTTP_STATUS=$(curl -sS --config "$VAULT_CURL_CONFIG" -X "$method" \
            -H 'Content-Type: application/json' --data-binary "$body" \
            -o "$out" -w '%{http_code}' "$VAULT_ADDR/v1/$path")
    else
        VAULT_HTTP_STATUS=$(curl -sS --config "$VAULT_CURL_CONFIG" -X "$method" \
            -o "$out" -w '%{http_code}' "$VAULT_ADDR/v1/$path")
    fi
}

vault_existe() {
    vault_api GET "secret/data/$1"
    case "$VAULT_HTTP_STATUS" in
        200) return 0 ;;
        404) return 1 ;;
        # Erro não é "ausente": quem chama regeraria e sobrescreveria o segredo.
        *) echo "Vault respondeu HTTP $VAULT_HTTP_STATUS ao consultar $1." >&2; exit 1 ;;
    esac
}

vault_get() {
    vault_api GET "secret/data/$1"
    case "$VAULT_HTTP_STATUS" in
        200) python3 -c '
import json, sys
dados = json.load(sys.stdin)["data"]["data"]
valor = dados.get(sys.argv[1])
if valor is None:
    sys.exit("propriedade ausente: " + sys.argv[1])
print(valor, end="")' "$2" <"$VAULT_BODY_FILE" ;;
        404) return 1 ;;
        *) echo "Vault respondeu HTTP $VAULT_HTTP_STATUS ao ler $1." >&2; return 2 ;;
    esac
}

# vault_put <caminho> chave=valor...: o valor pode ter quebras de linha.
vault_put() {
    local path="$1" par
    shift
    local payload
    payload=$(
        for par in "$@"; do
            printf '%s\0' "$par"
        done | python3 -c '
import json, sys
dados = {}
for item in sys.stdin.buffer.read().split(b"\0"):
    if item:
        chave, _, valor = item.decode().partition("=")
        dados[chave] = valor
print(json.dumps({"data": dados}), end="")'
    )
    vault_api POST "secret/data/$path" "$payload"
    [[ "$VAULT_HTTP_STATUS" == 200 ]] || {
        echo "Vault respondeu HTTP $VAULT_HTTP_STATUS ao gravar $path." >&2
        return 1
    }
}
