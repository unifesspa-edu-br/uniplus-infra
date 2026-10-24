#!/usr/bin/env bash
# Provisiona no Vault de HML o que o KES, o RabbitMQ e o MinIO precisam para a
# cifra e a verificação dos arquivos do candidato (ADR-0146 do uniplus-api,
# uniplus-infra#682). É a parte "escrita no Vault" que os charts platform/kes e
# platform/rabbitmq não fazem:
#
#   - Transit `transit/` e a chave `uniplus-kes-kek` (cifra as chaves do KES);
#   - política `kes` e role Kubernetes auth `kes` (ServiceAccount kes/kes);
#   - certificado do servidor KES (secret/standalone/kes/server);
#   - identidades do KES: `minio` (generate/decrypt) e `provisioner` (cria a chave);
#   - senhas do RabbitMQ (admin, API, verificador);
#   - credenciais do MinIO para a API e para o verificador.
#
# Idempotente: o que já existe no Vault é preservado, nunca regerado (regerar uma
# identidade ou uma senha desalinharia quem já a usa). Rodar na VM de HML, com o
# Vault inicializado e aberto, ANTES de o ArgoCD sincronizar o KES e o RabbitMQ.
# Em seguida, rodar provision-arquivos-candidato.sh.
#
# Uso: ./provision-verificacao-prerequisites.sh
#
# Variáveis:
#   HOST_IP     IP do host (entra na SAN do certificado do KES). Default 192.168.21.134.
#   KES_IMAGE   Imagem do KES usada para gerar as identidades.
set -euo pipefail

HOST_IP="${HOST_IP:-192.168.21.134}"
KES_IMAGE="${KES_IMAGE:-quay.io/minio/kes:2025-03-12T09-35-18Z}"
KES_NAMESPACE="kes"
KES_SERVICE_ACCOUNT="kes"
TRANSIT_KEY="uniplus-kes-kek"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmpdir=$(mktemp -d)
chmod 700 "$tmpdir"
cleanup() {
    vault_desconectar 2>/dev/null || true
    rm -rf "$tmpdir"
}
trap cleanup EXIT

# shellcheck source=lib-vault.sh
source "$SCRIPT_DIR/lib-vault.sh"
command -v docker >/dev/null || { echo "Comando obrigatório ausente: docker" >&2; exit 1; }
vault_conectar "$tmpdir"

log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# --- Transit e chave que cifra as chaves mestras do KES ----------------------
vault_api GET sys/mounts
[[ "$VAULT_HTTP_STATUS" == 200 ]] || { echo "Falha ao listar mounts (HTTP $VAULT_HTTP_STATUS)." >&2; exit 1; }
if ! grep -q '"transit/"' "$VAULT_BODY_FILE"; then
    log "Habilitando o mount transit/"
    vault_api POST sys/mounts/transit '{"type":"transit"}'
    [[ "$VAULT_HTTP_STATUS" == 204 ]] || { echo "Falha ao habilitar transit (HTTP $VAULT_HTTP_STATUS)." >&2; exit 1; }
fi
vault_api GET "transit/keys/$TRANSIT_KEY"
if [[ "$VAULT_HTTP_STATUS" == 404 ]]; then
    log "Criando a chave Transit $TRANSIT_KEY (não exportável, sem backup em claro)"
    vault_api POST "transit/keys/$TRANSIT_KEY" \
        '{"type":"aes256-gcm96","exportable":false,"allow_plaintext_backup":false}'
    [[ "$VAULT_HTTP_STATUS" == 204 ]] || { echo "Falha ao criar a chave Transit (HTTP $VAULT_HTTP_STATUS)." >&2; exit 1; }
elif [[ "$VAULT_HTTP_STATUS" != 200 ]]; then
    echo "Falha ao consultar a chave Transit (HTTP $VAULT_HTTP_STATUS)." >&2
    exit 1
fi

# --- Política e role do KES --------------------------------------------------
# O KES só toca o próprio prefixo no KV e cifra/decifra com a própria chave Transit.
politica=$(python3 -c '
import json, sys
t = sys.argv[1]
print(json.dumps({"policy": "\n".join([
    "path \"secret/data/kes/*\" { capabilities = [\"create\", \"read\", \"delete\"] }",
    "path \"secret/metadata/kes/*\" { capabilities = [\"list\", \"delete\"] }",
    "path \"secret/metadata/kes\" { capabilities = [\"list\"] }",
    "path \"transit/encrypt/%s\" { capabilities = [\"update\"] }" % t,
    "path \"transit/decrypt/%s\" { capabilities = [\"update\"] }" % t,
]) + "\n"}), end="")' "$TRANSIT_KEY")
log "Escrevendo a política kes"
vault_api PUT sys/policies/acl/kes "$politica"
[[ "$VAULT_HTTP_STATUS" == 204 ]] || { echo "Falha ao escrever a política kes (HTTP $VAULT_HTTP_STATUS)." >&2; exit 1; }

log "Escrevendo a role Kubernetes auth kes"
vault_api POST auth/kubernetes/role/kes "$(python3 -c '
import json, sys
print(json.dumps({
    "bound_service_account_names": sys.argv[1],
    "bound_service_account_namespaces": sys.argv[2],
    "policies": "kes",
    "audience": "https://kubernetes.default.svc.cluster.local",
    "ttl": "1h",
}), end="")' "$KES_SERVICE_ACCOUNT" "$KES_NAMESPACE")"
[[ "$VAULT_HTTP_STATUS" == 204 ]] || {
    echo "Falha ao escrever a role kes (HTTP $VAULT_HTTP_STATUS). O auth kubernetes está habilitado?" >&2
    exit 1
}

# --- Certificado do servidor KES --------------------------------------------
# Autoassinado (não há cert-manager em HML) e válido por 1 ano. A SAN inclui o IP
# do host, porque o MinIO chega pelo hostPort. Rotação: apagar
# secret/standalone/kes/server no Vault e rodar este script e o seguinte de novo.
if vault_existe standalone/kes/server; then
    log "Certificado do KES já existe no Vault — preservado."
else
    log "Gerando o certificado do servidor KES"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
        -keyout "$tmpdir/kes.key" -out "$tmpdir/kes.crt" -days 365 -subj "/CN=kes" \
        -addext "subjectAltName=DNS:kes,DNS:kes.${KES_NAMESPACE}.svc,DNS:kes.${KES_NAMESPACE}.svc.cluster.local,DNS:localhost,IP:${HOST_IP},IP:127.0.0.1" \
        2>/dev/null
    vault_put standalone/kes/server "cert=$(cat "$tmpdir/kes.crt")" "key=$(cat "$tmpdir/kes.key")"
    shred -u "$tmpdir/kes.key" 2>/dev/null || rm -f "$tmpdir/kes.key"
fi

# --- Identidades do KES ------------------------------------------------------
# A chave de API é o segredo; a identidade (hash) é o que a política do KES lista.
# As duas chaves ficam em custódia no Vault; só a do MinIO sai de lá, para o host.
tem_identidades=false
tem_chaves=false
vault_existe standalone/kes/identities && tem_identidades=true
vault_existe standalone/kes/api-keys && tem_chaves=true
if [[ "$tem_identidades" != "$tem_chaves" ]]; then
    # Regerar as duas desalinharia o que já usa a que sobrou (a política do KES
    # lista a identidade; o MinIO guarda a chave de API). Decisão do operador.
    echo "Estado inconsistente: só um entre standalone/kes/identities e standalone/kes/api-keys existe no Vault." >&2
    echo "Restaure o que falta ou apague o que sobrou (e reaplique o KES e o MinIO) antes de rodar de novo." >&2
    exit 1
fi
if [[ "$tem_identidades" == true ]]; then
    log "Identidades do KES já existem no Vault — preservadas."
else
    log "Gerando as identidades minio e provisioner do KES"
    # `identity new` imprime a chave de API e a identidade (SHA-256, 64 hex) juntas.
    # Cada chamada devolve uma chave e a identidade dela.
    nova_identidade() {
        local saida chave identidade
        saida=$(sudo docker run --rm "$KES_IMAGE" identity new)
        chave=$(grep -o -m1 'kes:v1:[A-Za-z0-9+/=]*' <<<"$saida") || return 1
        identidade=$(grep -oE -m1 '\b[0-9a-f]{64}\b' <<<"$saida") || return 1
        printf '%s %s\n' "$chave" "$identidade"
    }
    par_minio=$(nova_identidade) || { echo "Falha ao gerar a identidade do MinIO no KES." >&2; exit 1; }
    par_provisioner=$(nova_identidade) || { echo "Falha ao gerar a identidade de provisionamento no KES." >&2; exit 1; }
    read -r chave_minio id_minio <<<"$par_minio"
    read -r chave_provisioner id_provisioner <<<"$par_provisioner"
    [[ -n "$chave_minio" && -n "$id_minio" && -n "$chave_provisioner" && -n "$id_provisioner" && "$id_minio" != "$id_provisioner" ]] || {
        echo "Falha ao derivar as identidades do KES." >&2
        exit 1
    }
    vault_put standalone/kes/api-keys "minio=$chave_minio" "provisioner=$chave_provisioner"
    vault_put standalone/kes/identities "minio=$id_minio" "provisioner=$id_provisioner"
    unset chave_minio chave_provisioner id_minio id_provisioner par_minio par_provisioner
fi

# --- Senhas do RabbitMQ ------------------------------------------------------
# Os nomes de usuário têm de bater com rabbitmq.users no chart platform/rabbitmq.
garantir_credencial() {
    local caminho="$1" usuario="$2"
    if vault_existe "$caminho"; then
        log "Credencial $caminho já existe no Vault — preservada."
    else
        log "Gerando a credencial $caminho"
        vault_put "$caminho" "username=$usuario" "password=$(openssl rand -hex 24)"
    fi
}
garantir_credencial standalone/rabbitmq/admin rabbitmq-admin
garantir_credencial standalone/rabbitmq/api uniplus-api
garantir_credencial standalone/rabbitmq/verificador uniplus-verificador

# --- Credenciais do MinIO para a API e para o verificador ---------------------
# O provision-arquivos-candidato.sh cria os usuários no MinIO a partir daqui.
garantir_minio() {
    local caminho="$1" usuario="$2"
    if vault_existe "$caminho"; then
        log "Credencial $caminho já existe no Vault — preservada."
    else
        log "Gerando a credencial $caminho"
        vault_put "$caminho" "access_key=$usuario" "secret_key=$(openssl rand -hex 24)"
    fi
}
garantir_minio standalone/minio/arquivos-candidato-api uniplus-api-arquivos
garantir_minio standalone/minio/arquivos-candidato-verificador uniplus-verificador-arquivos

echo "Pré-requisitos da verificação provisionados no Vault. Próximo: sincronizar o KES e o RabbitMQ no ArgoCD e rodar provision-arquivos-candidato.sh."
