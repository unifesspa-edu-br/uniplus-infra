#!/usr/bin/env bash
# Funções e constantes comuns aos scripts de produção (duas VMs). É carregado
# com `source`, nunca executado. Cada script que o carrega define DRY_RUN antes
# de chamar `run`, e analisa os argumentos com `analisar_argumentos`.

# Ambiente: prd (padrão) ou hml. Nomeia o cluster no ArgoCD (uniplus-<ambiente>) e
# os KVs do Vault (<sistema>-<ambiente>). Os endereços das VMs vêm das variáveis abaixo.
AMBIENTE="${AMBIENTE:-prd}"
APP_IP="${APP_IP:-200.139.48.121}"
INFRA_IP="${INFRA_IP:-200.139.48.122}"
# VM de automação: só o role de backup alcança o PostgreSQL a partir dela.
AUTOMACAO_IP="${AUTOMACAO_IP:-200.139.48.114}"
ROLE_BACKUP="${ROLE_BACKUP:-uniplus_backup}"
INFRA_FQDN_INFORMADO="${INFRA_FQDN:-}"
INFRA_FQDN="${INFRA_FQDN:-uniplus-prod-infra.unifesspa.edu.br}"
# Origem das conexões da aplicação aos serviços de dados. Com as duas VMs, é o
# IP da VM de aplicação; num host só, os pods chegam com o IP da rede de pods.
APP_CIDR="${APP_CIDR:-$APP_IP/32}"
DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
TLS_DIR="${TLS_DIR:-/etc/uniplus/tls}"
TLS_KEY="$TLS_DIR/unifesspa.edu.br.key"
TLS_BUNDLE="$TLS_DIR/unifesspa.edu.br-bundle.crt"
# Nomes do ambiente: o do Vault (rota do Traefik, certificado do domínio) e o da VM
# de aplicação (K3s, KES). Em produção são fixos; em outro ambiente precisam ser
# informados, para que um script de HML nunca alcance produção por omissão.
if [[ "$AMBIENTE" == prd ]]; then
    NOME_DO_VAULT="${NOME_DO_VAULT:-uniplus-vault.unifesspa.edu.br}"
    APP_FQDN="${APP_FQDN:-uniplus-prod-app.unifesspa.edu.br}"
else
    NOME_DO_VAULT="${NOME_DO_VAULT:-}"
    APP_FQDN="${APP_FQDN:-}"
fi
DRY_RUN=false

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[ OK ] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_error()   { echo "[ERRO] $*" >&2; }

case "$AMBIENTE" in
    prd|hml) ;;
    *) log_error "AMBIENTE inválido: '$AMBIENTE' (use prd ou hml)."; exit 2 ;;
esac

# Define VAULT_URL só quando a variável não existe. Vazio definido de propósito é
# respeitado e significa "usar o port-forward do host do cluster" (lib-vault.sh).
definir_url_do_vault() {
    if [[ -v VAULT_URL ]]; then
        export VAULT_URL
        return 0
    fi
    [[ -n "$NOME_DO_VAULT" ]] || {
        log_error "Informe NOME_DO_VAULT (nome público do Vault de AMBIENTE=$AMBIENTE) ou VAULT_URL."
        exit 2
    }
    export VAULT_URL="https://$NOME_DO_VAULT"
}

exigir_app_fqdn() {
    [[ -n "$APP_FQDN" ]] || {
        log_error "Informe APP_FQDN (nome da VM de aplicação de AMBIENTE=$AMBIENTE)."
        exit 2
    }
}

# O padrão de INFRA_FQDN é o da produção; fora dela o nome precisa ser informado,
# para que um script de HML nunca alcance os serviços de dados de produção.
exigir_infra_fqdn() {
    [[ "$AMBIENTE" == prd || -n "$INFRA_FQDN_INFORMADO" ]] || {
        log_error "Informe INFRA_FQDN (nome da VM de dados de AMBIENTE=$AMBIENTE)."
        exit 2
    }
}

# Executa o comando, ou só o mostra em --dry-run.
run() {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        bash -c "$*"
    fi
}

analisar_argumentos() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            -h|--help) mostrar_uso; exit 0 ;;
            *) log_error "Opção inválida: $arg"; exit 2 ;;
        esac
    done
}

exigir_usuario_comum() {
    if [[ "$(id -u)" -eq 0 ]]; then
        log_error "Não rode como root; use um usuário com sudo sem senha."
        exit 1
    fi
}

# O par de certificado e chave é instalado por quem opera a VM, fora do
# repositório. Em --dry-run só avisa.
exigir_par_tls() {
    if $DRY_RUN; then
        log_warn "Dry-run: $TLS_KEY e $TLS_BUNDLE seriam exigidos."
        return 0
    fi
    if sudo test -r "$TLS_KEY" && sudo test -r "$TLS_BUNDLE"; then
        return 0
    fi
    log_error "Par TLS ausente em $TLS_DIR (unifesspa.edu.br.key e unifesspa.edu.br-bundle.crt)."
    exit 1
}

# Copia o par TLS para o diretório de um serviço com o dono que o container usa.
# Uso: instalar_par_tls <destino> <uid> <nome-cert> <nome-chave>
instalar_par_tls() {
    local destino="$1" uid="$2" cert="${3:-public.crt}" chave="${4:-private.key}"
    if $DRY_RUN; then
        echo "[DRY-RUN] instalar $TLS_BUNDLE e $TLS_KEY em $destino (uid $uid)"
        return 0
    fi
    sudo install -d -m 750 -o "$uid" -g "$uid" "$destino"
    sudo install -m 644 -o "$uid" -g "$uid" "$TLS_BUNDLE" "$destino/$cert"
    sudo install -m 600 -o "$uid" -g "$uid" "$TLS_KEY" "$destino/$chave"
}

# Lê "chave=valor" de um arquivo de credenciais root:root 0600.
ler_credencial() {
    local arquivo="$1" chave="$2"
    sudo grep "^${chave}=" "$arquivo" | cut -d= -f2-
}

# Grava um arquivo root:root com o modo dado, lendo o conteúdo da entrada padrão.
gravar_arquivo_root() {
    local destino="$1" modo="$2"
    if $DRY_RUN; then
        echo "[DRY-RUN] gravaria $destino (modo $modo)"
        cat >/dev/null
        return 0
    fi
    sudo tee "$destino" >/dev/null
    sudo chown root:root "$destino"
    sudo chmod "$modo" "$destino"
}

# Gera a credencial no arquivo, uma vez; nunca a imprime nem a passa por argv.
garantir_credencial() {
    local arquivo="$1" chave="$2"
    if $DRY_RUN; then
        echo "[DRY-RUN] garantiria ${chave} em $arquivo"
        return 0
    fi
    if sudo test -f "$arquivo"; then
        return 0
    fi
    printf '%s=%s\n' "$chave" "$(openssl rand -hex 32)" | gravar_arquivo_root "$arquivo" 600
    log_warn "Credencial gerada em $arquivo; a custódia segue o runbook."
}

garantir_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_success "Docker já instalado."
        return 0
    fi
    run "sudo apt-get update -qq"
    run "sudo apt-get install -y docker.io"
    run "sudo systemctl enable --now docker"
}

# Sem swap: falta de memória precisa aparecer como processo encerrado, não como
# lentidão sem causa visível. Desliga o swap ativo e comenta as linhas de swap do
# /etc/fstab, para que não volte no próximo boot.
desligar_swap() {
    if $DRY_RUN; then
        echo "[DRY-RUN] swapoff -a e comentaria as linhas de swap do /etc/fstab"
        return 0
    fi
    sudo swapoff -a
    if grep -qE '^[^#].*[[:space:]]swap[[:space:]]' /etc/fstab; then
        sudo sed -i -E 's|^([^#].*[[:space:]]swap[[:space:]].*)$|# \1|' /etc/fstab
        sudo systemctl daemon-reload
    fi
    log_success "Swap desligado."
}

# Reinicia as unidades listadas, esperando cada uma voltar a ficar ativa.
reiniciar_unidades() {
    local unidade
    for unidade in "$@"; do
        run "sudo systemctl restart $unidade"
        run "sudo systemctl is-active --quiet $unidade"
    done
}
