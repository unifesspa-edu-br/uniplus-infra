# ADR 0001: Três DCs lógicos e clusters K8s independentes

- **Status:** ✅ Aceito
- **Data:** 2026-04-20
- **Relacionado:** [Issue #17](https://github.com/unifesspa-edu-br/uniplus-infra/issues/17)

## Contexto

A plataforma Uni+ precisa operar com alta disponibilidade e soberania de dados. O cenário físico envolve dois datacenters externos (EVEO em Cotia/SP e Osasco/SP) e um datacenter institucional (PA1 em Marabá/PA). Precisamos decidir como os clusters Kubernetes serão organizados entre esses locais.

As opções avaliadas foram:
1.  **Cluster K8s Único Estendido:** Um único plano de controle gerenciando nós em todos os DCs.
2.  **Clusters Independentes:** Clusters K8s separados por DC, com sincronização na camada de aplicação/dados.

## Decisão

Adotar **clusters Kubernetes independentes** em `SP1` e `SP2`. O DC institucional `PA1` atuará como local para identidade (origem), backup, retenção e funções de consenso (witness) quando aplicável.

Não haverá cluster estendido entre datacenters geográficos.

## Consequências

- ✅ **Resiliência de Rede:** Falhas no link inter-DC ou latência excessiva não derrubam o plano de controle do cluster.
- ✅ **Isolamento de Falha:** Erros de configuração ou problemas no etcd de um cluster não afetam o outro automaticamente.
- ✅ **Upgrades Graduais:** Manutenções e atualizações de versão do K8s podem ser realizadas cluster por cluster.
- ✅ **Autonomia do DC Institucional:** A indisponibilidade temporária de `PA1` não interrompe o atendimento normal de tráfego em `SP1` e `SP2`.
- ⚠️ **Drift de Configuração:** Exige rigor no uso de GitOps (ArgoCD) para garantir que as definições permaneçam idênticas entre os clusters.
- ⚠️ **Consistência:** O estado entre DCs passa a ser eventualmente consistente na camada de dados, o que é aceitável para o domínio de processos seletivos.
