# ADR-007: Vault HA com auto-unseal Transit centralizado em PA1

- **Status:** ✅ Aceito
- **Data:** 2026-05-03
- **Relacionado:** [Issue #13](https://github.com/unifesspa-edu-br/uniplus-infra/issues/13)

## Contexto

A plataforma Uni+ centraliza secrets (credenciais de banco, tokens de integração, chaves Gov.br, etc.) no HashiCorp Vault. A issue #13 pede a criação do chart `platform/vault/`, mas a especificação original deixou três pontos em aberto que não podem ser resolvidos isoladamente sem comprometer o desenho dos 3 DCs (ver [ADR-001](ADR-001-tres-dcs-logicos-e-clusters-k8s-independentes.md)):

1. **Topologia entre DCs.** O Vault OSS não tem replicação cross-cluster; SP1 e SP2 são clusters K3s independentes, e cada um precisa do seu próprio Vault HA. Como manter a operação coerente com "PA1 pode ficar fora algumas horas sem derrubar SP1/SP2"?
2. **Mecanismo de auto-unseal.** Reinicializar um Vault em produção sem auto-unseal exige operador presencial com shares de chave Shamir, o que é inviável para reinícios automáticos do K8s. AWS KMS é a opção padrão da indústria, mas viola a soberania institucional ([ADR-002](ADR-002-componentes-stateful-pesados-fora-do-kubernetes.md)).
3. **Validação no laboratório.** O propósito do lab `lab-{sp1,sp2,pa1}` é simular os 3 DCs reais com fidelidade topológica para servir de modelo de referência à DIRSI (avaliação de roteamento, firewall, regras do Palo Alto). Modos "dev simplificado" no lab escondem decisões arquiteturais que precisam ser validadas antes de produção.

## Alternativas consideradas

1. **Auto-unseal via AWS KMS.** Padrão da comunidade Vault, oficial e bem testado.
   - ❌ Rejeitada: viola a soberania institucional (Unifesspa não tem conta AWS contratada e o projeto não pode depender de provedor externo para reinícios). Conflita com a diretriz dos ADR-001 e ADR-002.

2. **Vault Enterprise com replication entre DCs.** Performance/DR replication nativa cobre o cenário de SP1↔SP2.
   - ❌ Rejeitada: licenciamento Enterprise não está no orçamento do projeto. Vault OSS atende com a topologia escolhida.

3. **Vault central único em PA1, consumido por SP1 e SP2.** Reduz a operação a um único Vault.
   - ❌ Rejeitada: viola explicitamente o ADR-001 ("PA1 pode ficar fora algumas horas sem derrubar SP1/SP2"). Se PA1 cair, SP1/SP2 perdem acesso a secrets e ficam degradados.

4. **Auto-unseal faseado: dev em lab, Shamir em sanidade, Transit em HML/prod.** Plano original — simplifica o lab.
   - ❌ Rejeitada: contraria o propósito do laboratório. Se lab não exercita o caminho de auto-unseal real (porta 8200 cross-cluster SP1→PA1, SP2→PA1), problemas de roteamento/firewall só aparecem em sanidade ou depois. Além disso, o time de redes recebe documentação que não corresponde ao que será implantado.

5. **Vault Transit central em PA1, auto-unseal cross-cluster desde o lab.** Vault dedicado em PA1 hospeda apenas a engine Transit; Vaults de aplicação em SP1/SP2 unseals contra ele via tokens dedicados.
   - ✅ Escolhida.

## Decisão

Adotar **HashiCorp Vault OSS** com a seguinte topologia, **idêntica desde o laboratório até produção** (variando apenas escala de réplicas e recursos):

### Vaults de aplicação (clusters SP1 e SP2)

- Chart `platform/vault/` empacotando o chart upstream `hashicorp/vault`.
- **3 réplicas Raft** por cluster (Integrated Storage), independentes entre SP1 e SP2.
- Storage em PVC sobre `StorageClass` nomeada por ambiente (decisão delegada à sub-issue de StorageClass).
- Auto-unseal via `seal "transit"` apontando para o Vault Transit em PA1 do mesmo ambiente (`lab-pa1`, `san-pa1`, `hml-pa1`, `prod-pa1`).
- Recursos: 200m/256Mi → 500m/512Mi por réplica em prod (alinhado à Tabela 10.1 do ARCHITECTURE.md); recursos reduzidos em lab.

### Vault Transit central (cluster PA1)

- Chart `platform/vault-transit/` empacotando o mesmo chart upstream, configurado como **Transit-only**.
- **Engine Transit habilitada**, com chave dedicada e ACL liberando uso a tokens dos clusters SP1 e SP2.
- Selado por **Shamir 5/3** (não há nó-raiz superior — é a casca de ovo). Bootstrap manual operado pela DIRSI/CTIC, com guarda de shares conforme procedimento institucional.
- Escala: 1 réplica em `lab-pa1` e `san-pa1`, 3 réplicas Raft em `hml-pa1` e `prod-pa1`.

### Padrão canônico de chart wrapper

Este é o **primeiro chart funcional** do diretório `platform/`. A estrutura adotada (Chart.yaml com dependência upstream pinada, `templates/{networkpolicy,servicemonitor,ingressroute}.yaml` opcionais e gated por flags em values, labels Uni+ obrigatórios, NetworkPolicy restritiva por default) serve de template para os demais charts em #14, #15, #24, #26-30.

## Consequências

- ✅ **Topologia exercitada desde o lab.** Tráfego cross-cluster (8200/tcp SP1→PA1, SP2→PA1) é reproduzido em laboratório, permitindo à DIRSI avaliar regras de roteamento e firewall antes da fase de sanidade.
- ✅ **Auto-unseal sem provedor externo.** Reinícios de Pods do Vault em SP1/SP2 acontecem sem intervenção humana, mantendo a soberania institucional.
- ✅ **PA1 indisponível por horas mantém aplicação rodando.** Vaults SP1/SP2 já desbloqueados continuam servindo secrets; só novo restart de Pod do Vault precisa esperar PA1 voltar (documentado em RUNBOOKS).
- ✅ **DR previsível.** Snapshot do Raft em cada Vault + procedimento Shamir documentado para o Transit em PA1 cobrem cenários de perda de cluster e perda do próprio Transit.
- ⚠️ **Secrets não replicam entre SP1 e SP2.** Cada cluster mantém seu próprio conjunto de secrets via `ExternalSecret`. Políticas e configurações de secret stores ficam versionadas em GitOps; segredos em si vivem no Vault de cada DC.
- ⚠️ **Tráfego cross-DC novo.** Liberação de 8200/tcp entre SP1↔PA1 e SP2↔PA1 precisa ser combinada com a DIRSI antes de promover qualquer fase. Documentado em `docs/network-matrix.md`.
- ⚠️ **Bootstrap do Transit é manual.** O Vault Transit em PA1 inicia selado e exige unseal Shamir manual no primeiro provisionamento e após restore de DR. Procedimento detalhado em `docs/RUNBOOKS.md`.
- ⚠️ **PA1 vira ponto crítico para reinícios.** Embora SP1/SP2 mantenham operação durante queda de PA1, o tempo máximo aceitável de PA1 fora corresponde ao MTBF de reinício de Pods do Vault. Monitorar e priorizar restauração de PA1 acima de outros componentes secundários.
