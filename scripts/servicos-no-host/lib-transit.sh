#!/usr/bin/env bash
# Transit do Vault por sistema e ambiente: um mount por sistema (uniplus-<amb>-transit,
# geo-<amb>-transit, plataforma-<amb>-transit), as chaves de cada um e as
# políticas e roles das APIs que cifram. É carregado por configurar-vault.sh com
# `source`, depois de lib-provisionar.sh (usa vault_api e os logs de lib-comum.sh).
#
# As chaves são AES-256-GCM, não exportáveis, sem backup em claro e com a remoção
# bloqueada. Nunca se muda min_decryption_version nem se faz trim: isso tornaria
# ilegível o que já foi cifrado.

MOUNT_UNIPLUS="uniplus-$AMBIENTE-transit"
MOUNT_GEO="geo-$AMBIENTE-transit"
MOUNT_PLATAFORMA="plataforma-$AMBIENTE-transit"

# Chaves do Uni+ (nomes no código do uniplus-api). As *-aesgcm cifram e decifram;
# as demais só calculam HMAC (índice cego e resumo do código de confirmação).
CHAVES_AES_UNIPLUS=(
    uniplus-selecao-identificadores-aesgcm
    uniplus-selecao-sensiveis-aesgcm
    uniplus-discentes-identificadores-aesgcm
    uniplus-idempotency-aesgcm
)
CHAVES_HMAC_UNIPLUS=(
    uniplus-selecao-identificadores-hmac
    uniplus-selecao-sensiveis-hmac
    instalacao-codigo
)
CHAVES_AES_GEO=(geo-idempotency-aesgcm)
# Chave que cifra as chaves mestras do KES. O nome não muda: ela protege arquivos
# já cifrados.
CHAVES_PLATAFORMA=(uniplus-kes-kek)

# ServiceAccounts reais (nomes fixos nos charts) e namespaces das APIs que cifram.
# O uniplus-api-portal não cifra (não registra AddUniPlusEncryption), então não
# tem role nem política.
SA_API_HOST="uniplus-api-host"
NS_API_HOST="uniplus"
SA_GEO="unifesspa-geo-api"
NS_GEO="geo"

montar_transit() {
    local mount="$1"
    vault_api GET sys/mounts
    if grep -q "\"$mount/\"" "$VAULT_BODY_FILE"; then
        log_success "Mount $mount/ já existe."
    else
        exigir_sucesso POST "sys/mounts/$mount" '{"type":"transit"}'
        log_success "Mount $mount/ (Transit) criado."
    fi
}

# Cria a chave se não existe; se existe, recusa uma que não seja AES-256-GCM, que
# seja exportável ou que permita backup em claro. Em ambos os casos aplica
# deletion_allowed=false (config não altera mais nada na chave).
garantir_chave_transit() {
    local mount="$1" chave="$2"
    vault_api GET "$mount/keys/$chave"
    case "$VAULT_HTTP_STATUS" in
        404)
            exigir_sucesso POST "$mount/keys/$chave" \
                '{"type":"aes256-gcm96","exportable":false,"allow_plaintext_backup":false}'
            log_success "Chave $mount/$chave criada."
            ;;
        200)
            python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
sys.exit(0 if d["type"] == "aes256-gcm96" and not d["exportable"] and not d["allow_plaintext_backup"] else 1)' \
                <"$VAULT_BODY_FILE" || {
                log_error "A chave $mount/$chave existe com tipo diferente de aes256-gcm96, exportável ou com backup em claro."
                exit 1
            }
            log_success "Chave $mount/$chave já existe."
            ;;
        *)
            log_error "Vault respondeu HTTP $VAULT_HTTP_STATUS ao consultar $mount/keys/$chave."
            exit 1
            ;;
    esac
    exigir_sucesso POST "$mount/keys/$chave/config" '{"deletion_allowed":false}'
}

# Mínimo que o VaultSharp usa: update em encrypt/decrypt das chaves AES e em
# hmac/<chave> (e hmac/<chave>/<algoritmo>) das chaves HMAC.
# Uso: texto_da_politica_de_cifra <mount> "<chaves aes>" "<chaves hmac>" (listas
# separadas por espaço; qualquer uma pode ser vazia).
texto_da_politica_de_cifra() {
    local mount="$1" aes="$2" hmac="$3" chave
    for chave in $aes; do
        printf 'path "%s/encrypt/%s" { capabilities = ["update"] }\n' "$mount" "$chave"
        printf 'path "%s/decrypt/%s" { capabilities = ["update"] }\n' "$mount" "$chave"
    done
    for chave in $hmac; do
        printf 'path "%s/hmac/%s" { capabilities = ["update"] }\n' "$mount" "$chave"
        printf 'path "%s/hmac/%s/*" { capabilities = ["update"] }\n' "$mount" "$chave"
    done
}

# Política com o nome da API e role Kubernetes auth ligada à ServiceAccount dela.
# O audience é o do token padrão do K3s, o mesmo da role do KES.
criar_politica_e_role_de_api() {
    local nome="$1" namespace="$2" mount="$3" aes="$4" hmac="$5" politica
    politica=$(texto_da_politica_de_cifra "$mount" "$aes" "$hmac")
    exigir_sucesso PUT "sys/policies/acl/$nome" \
        "$(POLITICA="$politica" python3 -c 'import json, os; print(json.dumps({"policy": os.environ["POLITICA"]}))')"
    exigir_sucesso POST "auth/kubernetes/role/$nome" \
        "{\"bound_service_account_names\":\"$nome\",\"bound_service_account_namespaces\":\"$namespace\",\"policies\":\"$nome\",\"audience\":\"https://kubernetes.default.svc.cluster.local\",\"ttl\":\"1h\"}"
    log_success "Política e role $nome aplicadas ao Transit $mount."
}

configurar_transit() {
    local chave
    montar_transit "$MOUNT_UNIPLUS"
    montar_transit "$MOUNT_GEO"
    montar_transit "$MOUNT_PLATAFORMA"
    for chave in "${CHAVES_AES_UNIPLUS[@]}" "${CHAVES_HMAC_UNIPLUS[@]}"; do
        garantir_chave_transit "$MOUNT_UNIPLUS" "$chave"
    done
    for chave in "${CHAVES_AES_GEO[@]}"; do
        garantir_chave_transit "$MOUNT_GEO" "$chave"
    done
    for chave in "${CHAVES_PLATAFORMA[@]}"; do
        garantir_chave_transit "$MOUNT_PLATAFORMA" "$chave"
    done
    criar_politica_e_role_de_api "$SA_API_HOST" "$NS_API_HOST" "$MOUNT_UNIPLUS" \
        "${CHAVES_AES_UNIPLUS[*]}" "${CHAVES_HMAC_UNIPLUS[*]}"
    criar_politica_e_role_de_api "$SA_GEO" "$NS_GEO" "$MOUNT_GEO" "${CHAVES_AES_GEO[*]}" ""
}
