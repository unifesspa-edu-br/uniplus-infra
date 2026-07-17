#!/usr/bin/env bash
# Provisiona os pré-requisitos stateful do uniplus-api-host no HML single-node.
#
# Deve rodar na VM HML depois de setup-redis.sh e setup-minio.sh. ROOT_TOKEN é
# carregado de ~/.bashrc somente na memória do processo; nunca é escrito no
# repositório nem passado como argumento de linha de comando.
set -euo pipefail

HOST_IP="${HOST_IP:-192.168.21.134}"
DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
VAULT_NAMESPACE="vault"
VAULT_POD="${VAULT_POD:-platform-vault-in-cluster-0}"
VAULT_ADDR="http://127.0.0.1:18200"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -z "${ROOT_TOKEN:-}" ]]; then
    # SSH não abre um shell interativo e o ~/.bashrc retorna cedo nesse caso.
    # Captura o valor apenas em memória, sem imprimi-lo nem gravá-lo em arquivo.
    ROOT_TOKEN=$(bash -ic 'printf "%s" "${ROOT_TOKEN:-}"' 2>/dev/null)
fi
if [[ -z "${ROOT_TOKEN:-}" ]]; then
    echo "ROOT_TOKEN não foi encontrado após carregar ~/.bashrc." >&2
    exit 1
fi

for binary in docker kubectl curl openssl python3 base64; do
    command -v "$binary" >/dev/null || {
        echo "Comando obrigatório ausente: $binary" >&2
        exit 1
    }
done

# Redis e MinIO são pré-requisitos do Host e precisam ser criados no próprio
# fluxo HML, inclusive em uma VM reconstruída. Os wrappers compartilham as
# rotinas idempotentes já validadas no lab.
DATA_HOST_IP="$HOST_IP" "$SCRIPT_DIR/setup-redis.sh"
DATA_HOST_IP="$HOST_IP" "$SCRIPT_DIR/setup-minio.sh"

tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
pg_env="$tmpdir/postgres.env"
vault_curl_config="$tmpdir/vault.curl"
pf_log="$tmpdir/vault-port-forward.log"
pf_pid=""

cleanup() {
    [[ -n "$pf_pid" ]] && kill "$pf_pid" 2>/dev/null || true
    shred -u "$pg_env" "$vault_curl_config" 2>/dev/null || true
    rm -rf "$tmpdir"
    unset ROOT_TOKEN
}
trap cleanup EXIT

postgres_creds="$DATA_BASE/postgres/.bootstrap-creds"
host_creds="$DATA_BASE/postgres/.bootstrap-creds-uniplus"
encryption_creds="$DATA_BASE/api-host/.bootstrap-creds-encryption"
super_pw=$(sudo grep '^super_pw=' "$postgres_creds" | cut -d= -f2-)
if [[ -z "$super_pw" ]]; then
    echo "super_pw ausente em $postgres_creds." >&2
    exit 1
fi

printf 'PGPASSWORD=%s\n' "$super_pw" > "$pg_env"
chmod 600 "$pg_env"

role_exists=false
if sudo docker exec --env-file "$pg_env" uniplus-postgres \
    psql -U postgres -tAc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='uniplus'" \
    | grep -qx '1'; then
    role_exists=true
fi

if sudo test -f "$host_creds"; then
    host_pw=$(sudo grep '^uniplus_pw=' "$host_creds" | cut -d= -f2-)
    [[ -n "$host_pw" ]] || {
        echo "uniplus_pw vazio em $host_creds." >&2
        exit 1
    }
elif "$role_exists"; then
    echo "Role PostgreSQL uniplus existe, mas $host_creds está ausente; abortando para não desalinhar Vault." >&2
    exit 1
else
    host_pw=$(openssl rand -hex 32)
    printf 'uniplus_pw=%s\n' "$host_pw" | sudo tee "$host_creds" >/dev/null
    sudo chown root:root "$host_creds"
    sudo chmod 600 "$host_creds"
fi

printf 'PGPASSWORD=%s\nAPP_PW=%s\n' "$super_pw" "$host_pw" > "$pg_env"
chmod 600 "$pg_env"

sudo docker exec --env-file "$pg_env" -i uniplus-postgres \
    psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
\getenv app_pw APP_PW
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'uniplus') AS role_exists \gset
\if :role_exists
  ALTER ROLE uniplus WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\else
  CREATE ROLE uniplus WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif
SQL

if ! sudo docker exec --env-file "$pg_env" uniplus-postgres \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='uniplus'" | grep -qx '1'; then
    sudo docker exec --env-file "$pg_env" uniplus-postgres \
        psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE uniplus OWNER uniplus ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
fi
sudo docker exec --env-file "$pg_env" uniplus-postgres \
    psql -U postgres -v ON_ERROR_STOP=1 -c 'GRANT ALL PRIVILEGES ON DATABASE uniplus TO uniplus' >/dev/null

(
    sudo sh -c 'KUBECONFIG="$1" exec kubectl -n "$2" port-forward "pod/$3" 18200:8200' \
        sh "$KUBECONFIG_PATH" "$VAULT_NAMESPACE" "$VAULT_POD"
) >"$pf_log" 2>&1 &
pf_pid=$!
for _ in $(seq 1 30); do
    if curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null

printf 'header = "X-Vault-Token: %s"\n' "$ROOT_TOKEN" > "$vault_curl_config"
chmod 600 "$vault_curl_config"

vault_put_password() {
    local path="$1"
    local password="$2"
    printf '{"data":{"password":"%s"}}' "$password" | \
        curl -fsS --config "$vault_curl_config" -X POST --data-binary @- \
            "$VAULT_ADDR/v1/secret/data/$path" -o /dev/null
}

vault_put_credentials() {
    local path="$1"
    local username="$2"
    local password="$3"
    printf '{"data":{"username":"%s","password":"%s"}}' "$username" "$password" | \
        curl -fsS --config "$vault_curl_config" -X POST --data-binary @- \
            "$VAULT_ADDR/v1/secret/data/$path" -o /dev/null
}

vault_put_local_key() {
    local key="$1"
    printf '{"data":{"local_key":"%s"}}' "$key" | \
        curl -fsS --config "$vault_curl_config" -X POST --data-binary @- \
            "$VAULT_ADDR/v1/secret/data/secret/standalone/uniplus-api-host/encryption" -o /dev/null
}

# O arquivo local é a cópia operacional; o Vault é a custódia de recuperação.
# Se o arquivo se perder num rebuild que preservou o Vault, restaurar a chave
# original antes de criar qualquer Secret Kubernetes evita tornar os dados
# cifrados irrecuperáveis.
vault_get_local_key() {
    local response="$tmpdir/vault-encryption.json"
    local status
    local path

    # O ClusterSecretStore tem mount `secret` (KV v2), e os ExternalSecrets
    # referenciam remoteRef.key `secret/standalone/...`; a API correspondente
    # é /v1/secret/data/secret/standalone/.... O segundo caminho é só
    # compatibilidade com a primeira execução deste helper, antes da correção
    # da convenção, e é migrado pelo vault_put_local_key no mesmo re-run.
    for path in \
        'secret/data/secret/standalone/uniplus-api-host/encryption' \
        'secret/data/standalone/uniplus-api-host/encryption'; do
        status=$(curl -sS --config "$vault_curl_config" -o "$response" -w '%{http_code}' \
            "$VAULT_ADDR/v1/$path") || {
            echo "Falha ao consultar a custódia da chave local no Vault." >&2
            return 2
        }
        case "$status" in
            200)
                python3 -c 'import json, sys; print(json.load(sys.stdin)["data"]["data"]["local_key"])' < "$response" \
                    || return 3
                return 0
                ;;
            404) ;;
            *)
                echo "Vault retornou HTTP $status ao consultar a chave local." >&2
                return 2
                ;;
        esac
    done
    return 1
}

persist_local_key() {
    sudo install -d -m 700 "$DATA_BASE/api-host"
    printf 'local_key=%s\n' "$local_key" | sudo tee "$encryption_creds" >/dev/null
    sudo chown root:root "$encryption_creds"
    sudo chmod 600 "$encryption_creds"
}

if sudo test -f "$encryption_creds"; then
    local_key=$(sudo grep '^local_key=' "$encryption_creds" | cut -d= -f2-)
    [[ -n "$local_key" ]] || {
        echo "local_key vazio em $encryption_creds." >&2
        exit 1
    }
else
    if local_key=$(vault_get_local_key); then
        [[ -n "$local_key" ]] || {
            echo "local_key vazio na custódia do Vault." >&2
            exit 1
        }
        persist_local_key
    else
        vault_read_status=$?
        if [[ "$vault_read_status" -ne 1 ]]; then
            echo "Não foi possível recuperar a chave local existente do Vault; abortando." >&2
            exit 1
        fi
        local_key=$(openssl rand -base64 32)
        persist_local_key
    fi
fi

# Mesmo com a cópia local presente, não aceitar que ela substitua uma chave já
# custodiada no Vault. Isso cobre restaurações manuais/parciais antes de tocar
# no Secret runtime ou gravar qualquer novo valor no KV.
if vault_local_key=$(vault_get_local_key); then
    if [[ "$vault_local_key" != "$local_key" ]]; then
        echo "local_key diverge entre o arquivo local e a custódia do Vault; abortando." >&2
        exit 1
    fi
else
    vault_read_status=$?
    if [[ "$vault_read_status" -ne 1 ]]; then
        echo "Não foi possível verificar a chave local custodiada no Vault; abortando." >&2
        exit 1
    fi
fi

# A cópia runtime nunca é sobrescrita silenciosamente: uma divergência entre
# Kubernetes e a chave preservada indica recuperação incompleta ou custódia
# inconsistente. Parar aqui protege dados já cifrados e exige reconciliação
# explícita do operador.
if existing_secret_key=$(sudo KUBECONFIG="$KUBECONFIG_PATH" kubectl -n uniplus \
    get secret uniplus-api-host-encryption-local -o jsonpath='{.data.LOCAL_KEY}' 2>/dev/null); then
    existing_local_key=$(printf '%s' "$existing_secret_key" | base64 --decode) || {
        echo "LOCAL_KEY do Secret Kubernetes não é Base64 válido." >&2
        exit 1
    }
    if [[ "$existing_local_key" != "$local_key" ]]; then
        echo "LOCAL_KEY diverge entre Kubernetes e a custódia local/Vault; abortando sem sobrescrever a chave de runtime." >&2
        exit 1
    fi
else
    printf '%s\n' \
        'apiVersion: v1' \
        'kind: Secret' \
        'metadata:' \
        '  name: uniplus-api-host-encryption-local' \
        '  namespace: uniplus' \
        'type: Opaque' \
        'stringData:' \
        "  LOCAL_KEY: $local_key" | \
        sudo KUBECONFIG="$KUBECONFIG_PATH" kubectl apply -f - >/dev/null
fi
unset existing_secret_key existing_local_key vault_local_key vault_read_status

redis_pw=$(sudo grep '^default_pw=' "$DATA_BASE/redis/.bootstrap-creds" | cut -d= -f2-)
minio_user=$(sudo grep '^root_user=' "$DATA_BASE/minio/.bootstrap-creds" | cut -d= -f2-)
minio_pw=$(sudo grep '^root_pw=' "$DATA_BASE/minio/.bootstrap-creds" | cut -d= -f2-)
[[ -n "$redis_pw" && -n "$minio_user" && -n "$minio_pw" ]] || {
    echo "Credenciais Redis/MinIO incompletas; execute seus setups antes deste script." >&2
    exit 1
}

vault_put_password 'secret/standalone/postgres/uniplus' "$host_pw"
vault_put_password 'secret/standalone/redis/default' "$redis_pw"
vault_put_credentials 'secret/standalone/minio/root' "$minio_user" "$minio_pw"
vault_put_local_key "$local_key"

unset super_pw host_pw local_key redis_pw minio_user minio_pw
echo "Pré-requisitos do uniplus-api-host provisionados: Postgres, Vault e chave local de cifragem."
