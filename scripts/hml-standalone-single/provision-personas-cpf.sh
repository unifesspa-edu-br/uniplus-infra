#!/usr/bin/env bash
# Grava o CPF e o nome social das personas fictícias nos usuários do realm de HML.
#
# A inscrição do candidato exige o claim `cpf`, que o client scope
# `uniplus-profile` lê do atributo `cpf` do usuário. As personas
# (https://unifesspa-edu-br.github.io/uniplus-developers/personas/) já existem
# como usuários do realm, com senhas que não são publicadas; este script só
# completa o cadastro delas — não cria usuário nem toca em senha.
#
# Uso, na VM HML: provision-personas-cpf.sh [arquivo-ou-url-do-fake-people.json]
# As credenciais de admin do Keycloak vêm do Vault, lidas com o ROOT_TOKEN do
# ~/.bashrc só em memória, e passam apenas por arquivos de um tmpdir 0700.
set -euo pipefail

PERSONAS_ORIGEM="${1:-https://raw.githubusercontent.com/unifesspa-edu-br/uniplus-developers/main/src/data/fake-people.json}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
VAULT_POD="${VAULT_POD:-platform-vault-in-cluster-0}"
VAULT_ADDR="http://127.0.0.1:18200"
KEYCLOAK_SERVICE="${KEYCLOAK_SERVICE:-keycloak-replica-in-cluster}"
KEYCLOAK_ADDR="http://127.0.0.1:18080/auth"
REALM="${REALM:-unifesspa}"

if [[ -z "${ROOT_TOKEN:-}" ]]; then
    ROOT_TOKEN=$(bash -ic 'printf "%s" "${ROOT_TOKEN:-}"' 2>/dev/null)
fi
[[ -n "${ROOT_TOKEN:-}" ]] || { echo "ROOT_TOKEN não foi encontrado após carregar ~/.bashrc." >&2; exit 1; }

for binary in kubectl curl python3; do
    command -v "$binary" >/dev/null || { echo "Comando obrigatório ausente: $binary" >&2; exit 1; }
done

tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
pf_pids=()
cleanup() {
    for pid in "${pf_pids[@]}"; do kill "$pid" 2>/dev/null || true; done
    shred -u "$tmpdir"/* 2>/dev/null || true
    rm -rf "$tmpdir"
    unset ROOT_TOKEN
}
trap cleanup EXIT

if [[ -f "$PERSONAS_ORIGEM" ]]; then
    cp "$PERSONAS_ORIGEM" "$tmpdir/personas.json"
else
    curl -fsS "$PERSONAS_ORIGEM" -o "$tmpdir/personas.json"
fi

port_forward() {
    (
        sudo sh -c 'KUBECONFIG="$1" exec kubectl -n "$2" port-forward "$3" "$4"' \
            sh "$KUBECONFIG_PATH" "$1" "$2" "$3"
    ) >"$tmpdir/pf-$1.log" 2>&1 &
    pf_pids+=("$!")
}
port_forward vault "pod/$VAULT_POD" 18200:8200
port_forward uniplus "svc/$KEYCLOAK_SERVICE" 18080:8080
for _ in $(seq 1 30); do
    if curl -fsS "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1 \
        && curl -fsS "$KEYCLOAK_ADDR/realms/master" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

printf 'header = "X-Vault-Token: %s"\n' "$ROOT_TOKEN" > "$tmpdir/vault.curl"
chmod 600 "$tmpdir/vault.curl"
curl -fsS --config "$tmpdir/vault.curl" -o "$tmpdir/kc-admin.json" \
    "$VAULT_ADDR/v1/secret/data/standalone/keycloak/admin"

python3 - "$tmpdir" "$KEYCLOAK_ADDR" "$REALM" <<'PY'
import json, re, sys, urllib.parse, urllib.request

tmpdir, base, realm = sys.argv[1:4]
admin = json.load(open(f"{tmpdir}/kc-admin.json"))["data"]["data"]
login = urllib.parse.urlencode({"grant_type": "password", "client_id": "admin-cli",
                                "username": admin["username"], "password": admin["password"]}).encode()
token = json.load(urllib.request.urlopen(f"{base}/realms/master/protocol/openid-connect/token", login, timeout=30))["access_token"]
del admin, login

def chamar(metodo, caminho, corpo=None):
    req = urllib.request.Request(f"{base}/admin/realms/{realm}{caminho}", method=metodo,
                                 data=None if corpo is None else json.dumps(corpo).encode(),
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        conteudo = r.read()
        return json.loads(conteudo) if conteudo else None

personas = json.load(open(f"{tmpdir}/personas.json"))
atualizadas, ausentes = 0, []
for p in personas:
    achados = chamar("GET", "/users?" + urllib.parse.urlencode({"username": p["username"], "exact": "true"}))
    if not achados:
        ausentes.append(p["username"])
        continue
    usuario = chamar("GET", f"/users/{achados[0]['id']}")
    atributos = usuario.get("attributes") or {}
    atributos["cpf"] = [re.sub(r"\D", "", p["cpf"])]
    if p.get("nome_social"):
        atributos["nomeSocial"] = [p["nome_social"]]
    else:
        atributos.pop("nomeSocial", None)
    usuario["attributes"] = atributos
    chamar("PUT", f"/users/{usuario['id']}", usuario)
    atualizadas += 1

print(f"Personas atualizadas: {atualizadas} de {len(personas)}.")
if ausentes:
    print("Personas sem usuário no realm (não criadas por este script): " + ", ".join(ausentes))
PY
