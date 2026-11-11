#!/usr/bin/env bash
# Firewall da VM de infraestrutura: só a VM de aplicação alcança as portas dos
# serviços de dados, todas com TLS. A VM de automação alcança só o PostgreSQL, para
# o backup antes da migration. Carregado com `source` por bootstrap-infra.sh.
# Não mexe no acesso SSH nem liga o firewall: ele já vem ativo da VM.

PORTAS_INFRA=(5432 6379 9000 9092 5671 15671)

step_firewall() {
    log_info "Conferindo as regras do firewall da VM de infraestrutura..."
    local porta
    if ! $DRY_RUN && ! sudo ufw status | grep -q '^Status: active'; then
        log_warn "ufw inativo: ligue-o, liberando antes o SSH, e rode de novo."
        return 0
    fi
    for porta in "${PORTAS_INFRA[@]}"; do
        run "sudo ufw allow from $APP_IP to any port $porta proto tcp"
    done
    run "sudo ufw allow from $AUTOMACAO_IP to any port 5432 proto tcp"
}
