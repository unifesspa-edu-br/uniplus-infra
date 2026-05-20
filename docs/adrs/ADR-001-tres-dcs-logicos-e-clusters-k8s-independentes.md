# ADR-001: Três DCs lógicos e clusters K8s independentes

- **Status:** ⛔ Superseded — substituído por [ADR-008](ADR-008-topologia-standalone.md). O modelo dos 3 DCs (SP1+SP2+PA1) nunca foi provisionado; em 2026-05-19 a única infra operada é o ambiente `standalone-compact` (1 cluster K3s + data-host externo em OCI GRU).
- **Data:** 2026-04-20 · **Superseded em:** 2026-05-19
- **Relacionado:** [Issue #17](https://github.com/unifesspa-edu-br/uniplus-infra/issues/17)

## Contexto

A plataforma Uni+ precisa operar com alta disponibilidade e soberania de dados. O cenário físico envolve dois datacenters externos (EVEO em Cotia/SP e Osasco/SP) e um datacenter institucional (`PA1` em Marabá/PA). Precisamos decidir como os clusters Kubernetes serão organizados entre esses locais.

## Alternativas consideradas

1. **Cluster K8s único estendido entre DCs:** Um único plano de controle gerenciando nós em todos os datacenters.
   - ❌ Rejeitada: latência inter-DC inviabiliza o consenso do etcd; falha de link derruba o plano de controle inteiro; manutenção exige janela coordenada entre os 3 DCs.
2. **Clusters independentes por DC, sincronização na camada de aplicação/dados:** Cada DC opera um cluster K3s autônomo; replicação acontece nos componentes (Patroni para Postgres, KRaft para Kafka, etc.).
   - ✅ Escolhida.

## Decisão

Adotar **clusters Kubernetes independentes** em `SP1` e `SP2`. O DC institucional `PA1` atua como local para identidade (origem), backup, retenção e funções de consenso (witness) quando aplicável.

Não haverá cluster estendido entre datacenters geográficos.

## Consequências

- ✅ **Resiliência de rede:** Falhas no link inter-DC ou latência excessiva não derrubam o plano de controle do cluster.
- ✅ **Isolamento de falha:** Erros de configuração ou problemas no etcd de um cluster não afetam o outro automaticamente.
- ✅ **Upgrades graduais:** Manutenções e atualizações de versão do K8s podem ser realizadas cluster por cluster.
- ✅ **Autonomia do DC institucional:** A indisponibilidade temporária de `PA1` não interrompe o atendimento normal de tráfego em `SP1` e `SP2`.
- ⚠️ **Drift de configuração:** Exige rigor no uso de GitOps (ArgoCD — ver [ADR-006](ADR-006-gitops-com-argocd.md)) para garantir que as definições permaneçam idênticas entre os clusters.
- ⚠️ **Consistência:** O estado entre DCs passa a ser eventualmente consistente na camada de dados, o que é aceitável para o domínio de processos seletivos.
