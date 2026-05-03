# ADR-002: Componentes stateful pesados fora do Kubernetes

- **Status:** ✅ Aceito
- **Data:** 2026-04-20
- **Relacionado:** [Issue #18](https://github.com/unifesspa-edu-br/uniplus-infra/issues/18)

## Contexto

Componentes como PostgreSQL, Apache Kafka e MinIO são críticos para a persistência e mensageria da plataforma. Operá-los dentro do Kubernetes (usando Operators ou Helm Charts padrões) introduz camadas de abstração de rede e storage (CSI) que podem dificultar o troubleshooting e a recuperação em cenários de desastre total do cluster.

## Alternativas consideradas

1. **Stateful dentro do K8s via Operators (CloudNativePG, Strimzi, MinIO Operator):** Aproveitaria o mesmo plano de controle das aplicações.
   - ❌ Rejeitada: acoplamento entre a saúde do cluster e a integridade dos dados; CSI driver adiciona overhead de I/O; troubleshooting de PG/Kafka exige expertise em K8s + Operator.
2. **Stateful fora do K8s, no host Linux dos servidores dedicados:** Bancos rodam direto nos servidores físicos com acesso ao NVMe local.
   - ✅ Escolhida. O empacotamento (containers via systemd vs bare-metal) é decidido em [ADR-005](ADR-005-stateful-em-containers-via-systemd.md).

## Decisão

Operar **PostgreSQL, Kafka e MinIO fora do Kubernetes**, no host Linux dos servidores dedicados. O empacotamento é feito via containers gerenciados por systemd (ver [ADR-005](ADR-005-stateful-em-containers-via-systemd.md)) — não bare-metal.

## Justificativa

- **Performance de I/O:** Acesso direto ao storage NVMe sem o overhead do driver CSI do Kubernetes.
- **Isolamento de falha:** O banco de dados e as mensagens continuam acessíveis e operacionais mesmo que o plano de controle do Kubernetes ou o CNI (rede do cluster) falhe.
- **Simplicidade de DR:** Processos de backup (pgBackRest) e restore são realizados via ferramentas padrão do Linux, facilitando a vida do administrador em situações de crise.
- **Troubleshooting:** Redução da superfície de complexidade operacional ao eliminar abstrações de rede do Kubernetes para os serviços de dados.

## Consequências

- ✅ **Previsibilidade:** Latência de disco e rede mais estável para os bancos de dados.
- ✅ **Recuperabilidade:** Independência total entre a saúde do cluster K8s e a integridade dos dados.
- ⚠️ **Gestão híbrida:** A infraestrutura deve ser gerenciada tanto via Kubernetes (apps) quanto via ferramentas de automação de SO como Ansible (bancos).
- ⚠️ **Auto-healing:** Perde-se o reinício automático do K8s, substituído por mecanismos nativos (Patroni para PG, KRaft para Kafka) e pelo systemd como monitor de processo.
