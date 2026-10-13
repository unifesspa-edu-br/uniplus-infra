#!/usr/bin/env bash
# Provisiona os pré-requisitos stateful do uniplus-api-portal no HML single-node.
#
# Deve rodar na VM HML depois de provision-api-host-prerequisites.sh, que já
# publica no Vault os caminhos de Redis e MinIO lidos também pela Portal. Aqui
# fica só o que é exclusivo dela: o role e o banco próprios no Postgres e a
# senha em secret/standalone/postgres/portal, lida pelo ExternalSecret do chart.
#
# ROOT_TOKEN é carregado de ~/.bashrc somente na memória do processo; nunca é
# escrito no repositório nem passado como argumento de linha de comando.
set -euo pipefail

DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
VAULT_NAMESPACE="vault"
VAULT_POD="${VAULT_POD:-platform-vault-in-cluster-0}"
VAULT_ADDR="http://127.0.0.1:18200"
PORTAL_ROLE="portal"
PORTAL_DB="uniplus_portal"

if [[ -z "${ROOT_TOKEN:-}" ]]; then
    # SSH não abre um shell interativo e o ~/.bashrc retorna cedo nesse caso.
    # Captura o valor apenas em memória, sem imprimi-lo nem gravá-lo em arquivo.
    ROOT_TOKEN=$(bash -ic 'printf "%s" "${ROOT_TOKEN:-}"' 2>/dev/null)
fi
if [[ -z "${ROOT_TOKEN:-}" ]]; then
    echo "ROOT_TOKEN não foi encontrado após carregar ~/.bashrc." >&2
    exit 1
fi

for binary in docker kubectl curl openssl; do
    command -v "$binary" >/dev/null || {
        echo "Comando obrigatório ausente: $binary" >&2
        exit 1
    }
done

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
portal_creds="$DATA_BASE/postgres/.bootstrap-creds-portal"
super_pw=$(sudo grep '^super_pw=' "$postgres_creds" | cut -d= -f2-)
if [[ -z "$super_pw" ]]; then
    echo "super_pw ausente em $postgres_creds." >&2
    exit 1
fi

printf 'PGPASSWORD=%s\n' "$super_pw" > "$pg_env"
chmod 600 "$pg_env"

role_exists=false
if sudo docker exec --env-file "$pg_env" uniplus-postgres \
    psql -U postgres -tAc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname='$PORTAL_ROLE'" \
    | grep -qx '1'; then
    role_exists=true
fi

# O arquivo local é a fonte da senha: com o role já criado e o arquivo
# ausente, gerar outra senha desalinharia o Postgres do Vault em silêncio.
if sudo test -f "$portal_creds"; then
    portal_pw=$(sudo grep '^portal_pw=' "$portal_creds" | cut -d= -f2-)
    [[ -n "$portal_pw" ]] || {
        echo "portal_pw vazio em $portal_creds." >&2
        exit 1
    }
elif "$role_exists"; then
    echo "Role PostgreSQL $PORTAL_ROLE existe, mas $portal_creds está ausente; abortando para não desalinhar Vault." >&2
    exit 1
else
    portal_pw=$(openssl rand -hex 32)
    printf 'portal_pw=%s\n' "$portal_pw" | sudo tee "$portal_creds" >/dev/null
    sudo chown root:root "$portal_creds"
    sudo chmod 600 "$portal_creds"
fi

printf 'PGPASSWORD=%s\nAPP_PW=%s\n' "$super_pw" "$portal_pw" > "$pg_env"
chmod 600 "$pg_env"

sudo docker exec --env-file "$pg_env" -i uniplus-postgres \
    psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
\getenv app_pw APP_PW
SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = 'portal') AS role_exists \gset
\if :role_exists
  ALTER ROLE portal WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\else
  CREATE ROLE portal WITH LOGIN PASSWORD :'app_pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
\endif
SQL

if ! sudo docker exec --env-file "$pg_env" uniplus-postgres \
    psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PORTAL_DB'" | grep -qx '1'; then
    sudo docker exec --env-file "$pg_env" uniplus-postgres \
        psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE DATABASE $PORTAL_DB OWNER $PORTAL_ROLE ENCODING 'UTF8' LC_COLLATE 'C' LC_CTYPE 'C' TEMPLATE template0"
fi
sudo docker exec --env-file "$pg_env" uniplus-postgres \
    psql -U postgres -v ON_ERROR_STOP=1 -c "GRANT ALL PRIVILEGES ON DATABASE $PORTAL_DB TO $PORTAL_ROLE" >/dev/null

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

# O ClusterSecretStore usa o mount `secret` (KV v2) e o ESO descarta o nome do
# mount no início do remoteRef.key: `secret/standalone/postgres/portal` é lido
# em /v1/secret/data/standalone/postgres/portal.
printf '{"data":{"password":"%s"}}' "$portal_pw" | \
    curl -fsS --config "$vault_curl_config" -X POST --data-binary @- \
        "$VAULT_ADDR/v1/secret/data/standalone/postgres/portal" -o /dev/null

unset super_pw portal_pw
echo "Pré-requisitos do uniplus-api-portal provisionados: role e banco no Postgres e senha no Vault."
