#!/bin/sh
# shellcheck shell=sh
#
# Bootstrap declarativo e idempotente do Vault Transit no cluster local.
# Embutido como ConfigMap pelo chart vault-transit-bootstrap; executado por
# um Job Helm hook (post-install, post-upgrade, post-rollback).
#
# Operações (todas idempotentes):
#   1. Aguarda Vault unsealed via vault status (retries com backoff).
#   2. Habilita engine transit em ${TRANSIT_PATH} (skipa se já habilitado).
#   3. Cria a key AES-GCM-256 ${KEY_NAME} (skipa se já existe; flags são
#      consolidadas apenas na criação — alterações pós-existência ficam
#      fora deste bootstrap, escopo de RUNBOOK manual).
#   4. Escreve a policy ${POLICY_NAME} (sempre — vault policy write é
#      idempotente: substitui pelo conteúdo do stdin).
#   5. Escreve a role K8s auth ${ROLE_NAME} (idempotente).
#   6. Sanity checks com vault read, sem falhar em propriedades não-críticas.

set -eu

# --- Inputs (todos via env do Job) ----------------------------------------

VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR é obrigatório}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN é obrigatório (ExternalSecret deve materializar a Secret antes)}"
TRANSIT_PATH="${TRANSIT_PATH:-transit}"
KEY_NAME="${KEY_NAME:?KEY_NAME é obrigatório}"
KEY_TYPE="${KEY_TYPE:-aes256-gcm96}"
KEY_DELETION_ALLOWED="${KEY_DELETION_ALLOWED:-false}"
KEY_EXPORTABLE="${KEY_EXPORTABLE:-false}"
KEY_ALLOW_PLAINTEXT_BACKUP="${KEY_ALLOW_PLAINTEXT_BACKUP:-false}"
POLICY_NAME="${POLICY_NAME:?POLICY_NAME é obrigatório}"
ROLE_NAME="${ROLE_NAME:?ROLE_NAME é obrigatório}"
ROLE_SA="${ROLE_SA:?ROLE_SA é obrigatório}"
ROLE_NS="${ROLE_NS:?ROLE_NS é obrigatório}"
ROLE_TTL="${ROLE_TTL:-1h}"

VAULT_WAIT_MAX_ATTEMPTS="${VAULT_WAIT_MAX_ATTEMPTS:-60}"
VAULT_WAIT_SLEEP_SECONDS="${VAULT_WAIT_SLEEP_SECONDS:-5}"
VAULT_OP_MAX_RETRIES="${VAULT_OP_MAX_RETRIES:-5}"

export VAULT_ADDR VAULT_TOKEN

log() {
    printf '%s [vault-transit-bootstrap] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1"
}

# --- Retry wrapper para operações vault -----------------------------------

# Executa $@ até suceder ou esgotar VAULT_OP_MAX_RETRIES com backoff linear.
# Não esconde stderr da última tentativa.
retry_vault() {
    attempts=0
    while true; do
        attempts=$((attempts + 1))
        if "$@"; then
            return 0
        fi
        if [ "$attempts" -ge "$VAULT_OP_MAX_RETRIES" ]; then
            log "Operação falhou após $VAULT_OP_MAX_RETRIES tentativas: $*"
            return 1
        fi
        sleep_for=$((2 * attempts))
        log "Tentativa $attempts/$VAULT_OP_MAX_RETRIES falhou; retry em ${sleep_for}s"
        sleep "$sleep_for"
    done
}

# --- 1. Aguardar Vault unsealed -------------------------------------------
#
# `vault status` retorna 3 estados distintos por exit code (documentado em
# https://developer.hashicorp.com/vault/docs/commands/status):
#   0 = unsealed e acessível
#   1 = erro (rede, URL inválida, auth, etc.) — retry
#   2 = sealed mas alcançável — não retentar indefinidamente, abortar para
#       que o operador atue (unseal Shamir manual ou aguardar auto-unseal
#       OCI KMS/Transit). Vault pod com restart recente pode estar
#       transitoriamente sealed; toleramos algumas tentativas mas falhamos
#       em saturação.

log "Aguardando Vault em $VAULT_ADDR ficar disponível e unsealed"

attempts=0
sealed_attempts=0
sealed_max="${VAULT_SEALED_MAX_ATTEMPTS:-12}"  # ~1 min em sleep=5s

while true; do
    # `set -e` aborta o script em qualquer comando non-zero; capturamos o exit
    # code de `vault status` em rc via `|| rc=$?`, padrão POSIX que neutraliza
    # o errexit para esta chamada específica sem desabilitar globalmente.
    rc=0
    vault status >/dev/null 2>&1 || rc=$?

    if [ "$rc" -eq 0 ]; then
        log "Vault disponível e unsealed."
        break
    fi

    attempts=$((attempts + 1))

    if [ "$rc" -eq 2 ]; then
        sealed_attempts=$((sealed_attempts + 1))
        if [ "$sealed_attempts" -ge "$sealed_max" ]; then
            log "Vault permanece SEALED após $sealed_max tentativas. Bootstrap aborted — operador precisa fazer unseal."
            exit 1
        fi
        log "Vault sealed (tentativa sealed $sealed_attempts/$sealed_max); aguardando unseal..."
    else
        if [ "$attempts" -ge "$VAULT_WAIT_MAX_ATTEMPTS" ]; then
            log "Vault não acessível após $VAULT_WAIT_MAX_ATTEMPTS tentativas (último exit code: $rc)."
            vault status || true
            exit 1
        fi
        log "Vault não acessível (exit code $rc, tentativa $attempts/$VAULT_WAIT_MAX_ATTEMPTS); retry em ${VAULT_WAIT_SLEEP_SECONDS}s..."
    fi

    sleep "$VAULT_WAIT_SLEEP_SECONDS"
done

# --- 2. Habilitar transit (idempotente) -----------------------------------

if vault secrets list -format=json 2>/dev/null | grep -q "\"${TRANSIT_PATH}/\""; then
    log "Mount '${TRANSIT_PATH}/' já habilitado — skip enable."
else
    log "Habilitando mount '${TRANSIT_PATH}/'"
    retry_vault vault secrets enable -path="$TRANSIT_PATH" transit
fi

# --- 3. Criar key (apenas se não existe) ----------------------------------

# Helper: extrai um campo do output `vault read` (formato key-value tabulado).
# Uso: read_key_field <key_path> <field_name>
read_key_field() {
    vault read "$1" 2>/dev/null | awk -v field="$2" '$1 == field { print $2 }'
}

if vault read "${TRANSIT_PATH}/keys/${KEY_NAME}" >/dev/null 2>&1; then
    log "Key '${TRANSIT_PATH}/keys/${KEY_NAME}' já existe — validando drift de segurança."

    # Drift checks bloqueantes: type, exportable, allow_plaintext_backup.
    # Esses flags só são fixados na criação, então drift indica uma key
    # foi recriada por outro caminho fora do bootstrap. Abortar para
    # evitar mascarar problema de segurança.
    actual_type=$(read_key_field "${TRANSIT_PATH}/keys/${KEY_NAME}" "type")
    if [ "$actual_type" != "$KEY_TYPE" ]; then
        log "DRIFT: key '${KEY_NAME}' type='${actual_type}', esperado '${KEY_TYPE}'. Aborting."
        exit 1
    fi

    actual_exportable=$(read_key_field "${TRANSIT_PATH}/keys/${KEY_NAME}" "exportable")
    if [ "$actual_exportable" != "$KEY_EXPORTABLE" ]; then
        log "DRIFT: key '${KEY_NAME}' exportable='${actual_exportable}', esperado '${KEY_EXPORTABLE}'. Aborting."
        exit 1
    fi

    actual_plaintext=$(read_key_field "${TRANSIT_PATH}/keys/${KEY_NAME}" "allow_plaintext_backup")
    if [ "$actual_plaintext" != "$KEY_ALLOW_PLAINTEXT_BACKUP" ]; then
        log "DRIFT: key '${KEY_NAME}' allow_plaintext_backup='${actual_plaintext}', esperado '${KEY_ALLOW_PLAINTEXT_BACKUP}'. Aborting."
        exit 1
    fi

    log "Drift check OK: type/exportable/allow_plaintext_backup conformes."
else
    log "Criando key '${TRANSIT_PATH}/keys/${KEY_NAME}'"
    # exportable e allow_plaintext_backup são aceitos na criação;
    # deletion_allowed só é configurável via endpoint /config (passo abaixo).
    retry_vault vault write -f "${TRANSIT_PATH}/keys/${KEY_NAME}" \
        "type=${KEY_TYPE}" \
        "exportable=${KEY_EXPORTABLE}" \
        "allow_plaintext_backup=${KEY_ALLOW_PLAINTEXT_BACKUP}"
fi

# Reconciliar deletion_allowed em todo deploy (endpoint /config aceita apenas
# este flag + min_decryption_version + min_encryption_version + auto_rotate_period).
# Idempotente: mesma chamada produz mesma config.
log "Reconciliando deletion_allowed da key '${KEY_NAME}'"
retry_vault vault write "${TRANSIT_PATH}/keys/${KEY_NAME}/config" \
    "deletion_allowed=${KEY_DELETION_ALLOWED}"

# --- 4. Escrever policy (idempotente — vault policy write reemplaça) ------

log "Reconciliando policy '${POLICY_NAME}'"

# Policy least-privilege: apenas update em encrypt/decrypt para a key
# específica. Sem read, rewrap, datakey, export, backup, rotate — admin
# fica separado (root ou política dedicada).
#
# Escrevemos a policy em arquivo temp (em vez de pipe) porque vault policy
# write consome stdin de forma single-use; o wrapper de retry, se chamado
# via pipe, re-executa com EOF na segunda tentativa e produz policy vazia.
# /tmp é uma emptyDir do Pod, removido com o ciclo de vida do container.
policy_file="/tmp/uniplus-api-transit.hcl"
trap 'rm -f "$policy_file"' EXIT INT TERM
cat > "$policy_file" <<POLICY
path "${TRANSIT_PATH}/encrypt/${KEY_NAME}" {
  capabilities = ["update"]
}

path "${TRANSIT_PATH}/decrypt/${KEY_NAME}" {
  capabilities = ["update"]
}
POLICY

retry_vault vault policy write "$POLICY_NAME" "$policy_file"

# --- 5. Escrever role K8s auth (idempotente) ------------------------------

log "Reconciliando role 'auth/kubernetes/role/${ROLE_NAME}'"

retry_vault vault write "auth/kubernetes/role/${ROLE_NAME}" \
    "bound_service_account_names=${ROLE_SA}" \
    "bound_service_account_namespaces=${ROLE_NS}" \
    "policies=${POLICY_NAME}" \
    "ttl=${ROLE_TTL}"

# --- 6. Sanity checks (não-fatais) ----------------------------------------

log "=== Sanity check: transit mount ==="
vault secrets list 2>/dev/null | grep "^${TRANSIT_PATH}/" || true

log "=== Sanity check: transit key ==="
vault read "${TRANSIT_PATH}/keys/${KEY_NAME}" 2>/dev/null || true

log "=== Sanity check: kubernetes auth role ==="
vault read "auth/kubernetes/role/${ROLE_NAME}" 2>/dev/null || true

log "=== Sanity check: policy ==="
vault policy read "$POLICY_NAME" 2>/dev/null || true

log "Bootstrap concluído com sucesso."
