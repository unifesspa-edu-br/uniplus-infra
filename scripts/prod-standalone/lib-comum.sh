#!/usr/bin/env bash
# Funções e constantes comuns aos scripts de produção (duas VMs). É carregado
# com `source`, nunca executado. Cada script que o carrega define DRY_RUN antes
# de chamar `run`, e analisa os argumentos com `analisar_argumentos`.

APP_IP="${APP_IP:-200.139.48.121}"
INFRA_IP="${INFRA_IP:-200.139.48.122}"
INFRA_FQDN="${INFRA_FQDN:-uniplus-prod-infra.unifesspa.edu.br}"
# Origem das conexões da aplicação aos serviços de dados. Com as duas VMs, é o
# IP da VM de aplicação; num host só, os pods chegam com o IP da rede de pods.
APP_CIDR="${APP_CIDR:-$APP_IP/32}"
DATA_BASE="${DATA_BASE:-/var/lib/uniplus}"
TLS_DIR="${TLS_DIR:-/etc/uniplus/tls}"
TLS_KEY="$TLS_DIR/unifesspa.edu.br.key"
TLS_BUNDLE="$TLS_DIR/unifesspa.edu.br-bundle.crt"
DRY_RUN=false

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[ OK ] $*"; }
log_warn()    { echo "[WARN] $*"; }
log_error()   { echo "[ERRO] $*" >&2; }

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
