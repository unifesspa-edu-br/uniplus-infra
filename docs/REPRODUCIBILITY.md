# Reprodutibilidade da infraestrutura

Como garantir que o `uniplus-prd` pode ser recriado a partir deste repositório, com resultado previsível. A ordem dos passos está em [RUNBOOKS.md](RUNBOOKS.md#24-bootstrap-ordem).

## Camadas de garantia

| Camada | Comando | Prova |
|---|---|---|
| Estática | `make validate` | sintaxe YAML, schema dos charts, render Helm, nomes RFC 1123 |
| Idempotência | reexecutar `bootstrap-infra.sh` e `bootstrap-app.sh` numa VM já provisionada | o re-run não quebra nem duplica |
| Ensaio de recriação | bootstrap completo numa VM de teste | reprodutibilidade ponta a ponta |

Só o ensaio de recriação prova que o repositório sobe um ambiente funcional do zero; as demais camadas pegam regressões baratas antes dele.

## O que é codificado e o que é manual

| Etapa | Estado | Onde |
|---|---|---|
| Serviços da VM de infraestrutura | codificado | `scripts/servicos-no-host/bootstrap-infra.sh` |
| K3s, Helm e ArgoCD | codificado | `scripts/servicos-no-host/bootstrap-app.sh` |
| Charts de aplicação e plataforma | codificado (GitOps) | `apps/`, `platform/`, `environments/uniplus-prd/` |
| KV, políticas e roles do Vault | codificado | `configurar-vault.sh` |
| Segredos que nascem na infraestrutura | codificado | `semear-vault.sh`, `provisionar-*.sh` |
| Inicialização e abertura do Vault | manual | Shamir 5/3, chaves com custodiantes diferentes |
| Certificado curinga nas VMs | manual | instalado por quem opera a VM |
| Segredos que vêm de fora (SMTP, clients do Keycloak institucional) | manual | gravados no Vault por quem opera |

## Checklist dos passos manuais

- [ ] Instalar o certificado curinga em `/etc/uniplus/tls` nas duas VMs.
- [ ] Inicializar e abrir o Vault (`vault operator init -key-shares=5 -key-threshold=3`, três `unseal`).
- [ ] Rodar `configurar-vault.sh` antes de qualquer semente.
- [ ] Gravar os segredos que vêm de fora (ver o passo 7 do bootstrap no runbook).
- [ ] Sincronizar à mão as Applications na ordem do runbook e forçar o refresh dos ExternalSecrets.

## Critérios de sucesso

- `make validate` passa.
- Todas as Applications ficam `Synced` e `Healthy`.
- Os ExternalSecrets ficam `Ready` (nenhuma store recusa um namespace).
- O login SSO e o fluxo ponta a ponta funcionam pela interface.
