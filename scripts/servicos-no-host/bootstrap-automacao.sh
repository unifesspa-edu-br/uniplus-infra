#!/usr/bin/env bash
# Bootstrap da VM de automação da produção (uniplus-prod-automacao): executa os
# jobs de implantação de produção do repositório de implantação (GitLab
# institucional), em máquina separada das VMs de aplicação e de dados. Não hospeda
# aplicação nem dados.
#
# Uso:
#   ./bootstrap-automacao.sh [--dry-run] < arquivo-com-o-token-do-runner
#
# O token de autenticação do runner (glrt-...) é criado no GitLab, no projeto de
# implantação, e chega pela entrada padrão, nunca por argumento. Sem token, a VM é
# preparada e o registro do runner fica para uma nova execução.
#
# Pré-requisitos: Ubuntu 24.04 e usuário com sudo sem senha (não root), conectado
# pela rede institucional ou pela VPN, que são as únicas origens liberadas no SSH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-comum.sh
source "$SCRIPT_DIR/lib-comum.sh"

GITLAB_URL="https://gitlab.unifesspa.edu.br"
RUNNER_NOME="uniplus-prd"
# Mesma versão do runner de homologação.
RUNNER_VERSAO="19.5.3-1"
RUNNER_IMAGEM_PADRAO="alpine:3.22"
# Origens com acesso ao SSH: rede institucional e VPN.
ORIGENS_SSH=(200.139.48.0/25 192.168.90.0/24)
# Comentário das chaves de host geradas no template da CTIC: enquanto ele
# aparecer, a identidade da VM (chaves de host e machine-id) é a do template.
MARCA_DO_TEMPLATE="ubuntu-template"

mostrar_uso() {
    echo "Uso: $0 [--dry-run] < arquivo-com-o-token-do-runner"
}

# Chaves de host e machine-id copiados do template repetem a identidade de outras
# VMs: o SSH não distingue as máquinas e o journald e o DHCP as confundem. A chave
# ausente também dispara a troca, para uma execução interrompida no meio dela ser
# concluída na seguinte. Toda execução valida o sshd e o reinicia, o que mantém
# as sessões abertas e garante que ele sirva as chaves que estão no disco.
CHAVE_DE_HOST=/etc/ssh/ssh_host_ed25519_key.pub

# Gera as chaves novas num diretório à parte e só depois as move para /etc/ssh, a
# ed25519 por último: até ela chegar, a marca do template continua lá e a próxima
# execução refaz a troca. Em nenhum momento o sshd fica sem chaves.
trocar_chaves_de_host() {
    if $DRY_RUN; then
        echo "[DRY-RUN] gera chaves de host novas à parte e as move para /etc/ssh"
        return 0
    fi
    local novas
    novas="$(sudo mktemp -d)"
    sudo mkdir -p "$novas/etc/ssh"
    sudo ssh-keygen -A -f "$novas"
    sudo test -s "$novas$CHAVE_DE_HOST" || { log_error "ssh-keygen não gerou a chave ed25519."; exit 1; }
    sudo find "$novas/etc/ssh" -name 'ssh_host_*' ! -name 'ssh_host_ed25519_key*' -exec mv -f -t /etc/ssh {} +
    sudo mv -f "$novas/etc/ssh/ssh_host_ed25519_key" /etc/ssh/
    sudo mv -f "$novas$CHAVE_DE_HOST" /etc/ssh/
    sudo rm -rf "$novas"
}
step_identidade() {
    if sudo test -s "$CHAVE_DE_HOST" && ! sudo grep -qs "$MARCA_DO_TEMPLATE" "$CHAVE_DE_HOST"; then
        log_success "Identidade própria (chaves de host e machine-id)."
    else
        run "sudo rm -f /etc/machine-id /var/lib/dbus/machine-id"
        run "sudo systemd-machine-id-setup"
        trocar_chaves_de_host
        log_warn "Chaves de host novas: atualize o known_hosts de quem acessa a VM."
    fi
    run "sudo ssh-keygen -A"
    run "sudo sshd -t"
    run "sudo systemctl restart ssh"
}

# Confere que a sessão atual vem de uma origem que continuará com SSH, para o
# firewall não trancar quem está rodando o script. Sem SSH_CLIENT a origem é
# desconhecida: só segue quem declara estar no console da VM (CONSOLE=1).
exigir_origem_permitida() {
    local origem="${SSH_CLIENT:-}"
    origem="${origem%% *}"
    if [[ -z "$origem" ]]; then
        [[ "${CONSOLE:-}" == 1 ]] && return 0
        log_error "Origem da sessão desconhecida (sem SSH_CLIENT). No console da VM, rode com CONSOLE=1."
        exit 1
    fi
    if python3 - "$origem" "${ORIGENS_SSH[@]}" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(r) for r in sys.argv[2:]) else 1)
PY
    then
        return 0
    fi
    log_error "A sessão vem de $origem, fora de ${ORIGENS_SSH[*]}: o firewall cortaria o acesso."
    exit 1
}

# Regras de entrada desejadas, no formato de `ufw show added`.
regras_desejadas() {
    local origem
    for origem in "${ORIGENS_SSH[@]}"; do
        echo "ufw allow from $origem to any port 22 proto tcp"
    done
}

# Acrescenta as regras desejadas e só depois remove as demais: uma regra herdada
# (allow 22, OpenSSH) manteria o SSH aberto a qualquer origem com a entrada
# negada, e o firewall não fica desligado em momento algum.
step_firewall() {
    exigir_origem_permitida
    local regra
    while read -r regra; do
        run "sudo $regra"
    done < <(regras_desejadas)
    while read -r regra; do
        [[ "$regra" == ufw\ * ]] || continue
        regras_desejadas | grep -qxF "$regra" && continue
        if [[ "$regra" == "ufw route "* ]]; then
            run "sudo ufw route delete ${regra#ufw route }"
        else
            run "sudo ufw delete ${regra#ufw }"
        fi
    done < <(sudo ufw show added)
    run "sudo ufw default deny incoming"
    run "sudo ufw default allow outgoing"
    run "sudo ufw --force enable"
}

step_atualizacoes() {
    if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
        run "sudo apt-get install -y unattended-upgrades"
    fi
    run "printf '%s\n' 'APT::Periodic::Update-Package-Lists \"1\";' 'APT::Periodic::Unattended-Upgrade \"1\";' \
        | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null"
}

# Imagens dos jobs se acumulam a cada versão; a limpeza semanal mantém o disco.
step_limpeza_docker() {
    run "printf '%s\n' '#!/bin/sh' 'exec docker system prune --all --force --filter until=168h >/dev/null' \
        | sudo tee /etc/cron.weekly/uniplus-limpar-docker >/dev/null"
    run "sudo chmod 755 /etc/cron.weekly/uniplus-limpar-docker"
}

# Versão do pacote só quando está instalado e configurado (estado "ii", ou "hi"
# com o hold); um pacote com configuração interrompida é reinstalado.
versao_instalada() {
    local estado
    estado="$(dpkg-query -W -f='${db:Status-Abbrev}|${Version}' "$1" 2>/dev/null || true)"
    [[ "$estado" == [ih]"i |"* ]] && echo "${estado#*|}"
}

# O hold é reaplicado a cada execução, mesmo com a versão já instalada.
step_runner_pacote() {
    if [[ "$(versao_instalada gitlab-runner)" == "$RUNNER_VERSAO" \
        && "$(versao_instalada gitlab-runner-helper-images)" == "$RUNNER_VERSAO" ]]; then
        log_success "GitLab Runner $RUNNER_VERSAO já instalado."
        run "sudo apt-mark hold gitlab-runner gitlab-runner-helper-images"
        return 0
    fi
    local chave=/usr/share/keyrings/gitlab-runner.gpg
    run "curl -fsSL https://packages.gitlab.com/runner/gitlab-runner/gpgkey | sudo gpg --dearmor --yes -o $chave"
    run "echo 'deb [signed-by=$chave] https://packages.gitlab.com/runner/gitlab-runner/ubuntu noble main' \
        | sudo tee /etc/apt/sources.list.d/gitlab-runner.list >/dev/null"
    run "sudo apt-get update -qq"
    # Conclui uma instalação interrompida antes, que o apt recusaria sem isto.
    run "sudo dpkg --configure -a"
    run "sudo apt-mark unhold gitlab-runner gitlab-runner-helper-images"
    if ! run "sudo apt-get install -y --allow-downgrades gitlab-runner-helper-images=$RUNNER_VERSAO gitlab-runner=$RUNNER_VERSAO"; then
        run "sudo apt-mark hold gitlab-runner gitlab-runner-helper-images"
        log_error "Instalação do GitLab Runner $RUNNER_VERSAO falhou; pacotes mantidos em hold."
        exit 1
    fi
    run "sudo apt-mark hold gitlab-runner gitlab-runner-helper-images"
}

CONFIG_RUNNER=/etc/gitlab-runner/config.toml

# Lê o config.toml como TOML (tomllib) e confere os valores efetivos: no máximo um
# runner, e ele é o desta VM, com executor Docker não privilegiado e só o volume
# /cache (nada do host, como o socket do Docker). Saída 0 com o
# runner certo, 3 sem runner, 1 com divergência (mensagem na saída de erro).
conferir_config_runner() {
    sudo test -f "$CONFIG_RUNNER" || return 3
    sudo cat "$CONFIG_RUNNER" | python3 -c '
import sys, tomllib
nome, url, conc = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = tomllib.loads(sys.stdin.read())
runners = cfg.get("runners", [])
if not runners:
    sys.exit(3)
falhas = []
if len(runners) != 1:
    falhas.append(f"{len(runners)} runners, esperado um")
r = runners[0]
for campo, esperado in (("name", nome), ("url", url), ("executor", "docker")):
    if r.get(campo) != esperado:
        falhas.append(f"{campo}={r.get(campo)!r}")
docker = r.get("docker", {})
if docker.get("privileged") is not False:
    falhas.append("docker.privileged não é false")
volumes = docker.get("volumes")
if volumes != ["/cache"]:
    falhas.append(f"docker.volumes={volumes!r}, esperado só /cache")
concorrencia = cfg.get("concurrent")
if conc and concorrencia != 1:
    falhas.append(f"concurrent={concorrencia!r}")
if falhas:
    print("; ".join(falhas), file=sys.stderr)
    sys.exit(1)
' "$RUNNER_NOME" "$GITLAB_URL" "${1:-}"
}

# Antes de registrar, uma configuração divergente (outro runner, privilegiado)
# para a execução: o registro só acrescentaria um segundo runner.
exigir_config_runner_valida() {
    local situacao=0
    conferir_config_runner "$@" || situacao=$?
    if [[ $situacao == 1 ]]; then
        log_error "$CONFIG_RUNNER divergente: remova o registro (gitlab-runner unregister --all-runners) e rode de novo."
        exit 1
    fi
    return "$situacao"
}

# Registra o runner com o token da entrada padrão. O token não passa por argv:
# vai pela variável CI_SERVER_TOKEN, lida pelo gitlab-runner register.
step_runner_registro() {
    if exigir_config_runner_valida; then
        log_success "Runner $RUNNER_NOME já registrado."
        return 0
    fi
    local token=""
    if [[ ! -t 0 ]]; then
        IFS= read -r token || true
    fi
    if [[ -z "$token" ]]; then
        log_warn "Sem token na entrada padrão: o runner $RUNNER_NOME não foi registrado."
        return 0
    fi
    if $DRY_RUN; then
        echo "[DRY-RUN] gitlab-runner register $RUNNER_NOME (executor docker, não privilegiado)"
        return 0
    fi
    printf '%s\n' "$token" | sudo sh -c 'read -r T; CI_SERVER_TOKEN="$T" exec gitlab-runner register \
        --non-interactive --url "$1" --name "$2" --executor docker \
        --docker-image "$3" --docker-privileged=false --docker-volumes /cache' \
        registrar "$GITLAB_URL" "$RUNNER_NOME" "$RUNNER_IMAGEM_PADRAO" >/dev/null
    log_success "Runner $RUNNER_NOME registrado."
}

# Em toda execução, inclusive depois de um registro interrompido: um job por vez
# (concurrent = 1, gravado e conferido). O gitlab-runner recarrega o config.toml
# sozinho; o serviço nunca é reiniciado, só iniciado se estiver parado, para não
# interromper uma implantação em andamento.
step_runner_configuracao() {
    exigir_config_runner_valida || return 0
    if $DRY_RUN; then
        echo "[DRY-RUN] concurrent = 1 em $CONFIG_RUNNER e restart do gitlab-runner"
        return 0
    fi
    if sudo grep -qE '^[[:space:]]*concurrent[[:space:]]*=' "$CONFIG_RUNNER"; then
        sudo sed -i -E 's/^[[:space:]]*concurrent[[:space:]]*=.*/concurrent = 1/' "$CONFIG_RUNNER"
    else
        sudo sed -i '1i concurrent = 1' "$CONFIG_RUNNER"
    fi
    exigir_config_runner_valida com-concurrent
    sudo systemctl enable --now gitlab-runner
}

resumo() {
    cat <<RESUMO

VM de automação preparada.
  - Chave de host ed25519: $(sudo ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub 2>/dev/null | cut -d' ' -f2)
  - Runner: $(sudo gitlab-runner list 2>&1 | grep -c "^$RUNNER_NOME ") registrado como $RUNNER_NOME
Os jobs de produção passam a usar este runner pela tag $RUNNER_NOME no pipeline
do repositório de implantação (docs/RUNBOOKS.md, seção 2.7).
RESUMO
}

analisar_argumentos "$@"
exigir_usuario_comum
desligar_swap
step_identidade
step_firewall
step_atualizacoes
garantir_docker
run "sudo systemctl enable --now docker"
step_limpeza_docker
step_runner_pacote
step_runner_registro
step_runner_configuracao
resumo
