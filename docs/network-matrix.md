# Matriz de comunicação inter-DC

Este documento cataloga **todo o tráfego de rede entre os 3 DCs lógicos da plataforma Uni+** (`SP1`, `SP2`, `PA1`) — porta, protocolo, origem, destino, propósito e fase em que aparece. É a referência consultável pelo time da DIRSI para configurar regras de firewall (Palo Alto), roteamento e ACLs antes de promover a plataforma de uma fase para a próxima.

## Convenções

- **DCs lógicos** seguem a nomenclatura do [ADR-001](adrs/ADR-001-tres-dcs-logicos-e-clusters-k8s-independentes.md): `SP1` (EVEO Cotia), `SP2` (EVEO Osasco), `PA1` (Unifesspa Marabá).
- **Ambientes** combinam fase + DC (ex.: `lab-sp1`, `san-pa1`, `prod-sp2`). Ver [docs/ARCHITECTURE.md §5](ARCHITECTURE.md) e a sequência de validação `lab → sanidade → HML → prod`.
- **Tráfego intra-cluster** (entre Pods do mesmo K3s) **não** entra nesta matriz — fica encapsulado pelo CNI e governado por NetworkPolicies dos charts.
- **Tráfego intra-host** (entre containers no mesmo host fora do K8s, ex.: Postgres ↔ Patroni) também não entra — fica em `docs/RUNBOOKS.md`.
- Esta matriz cobre apenas: (a) tráfego cross-cluster K8s, (b) tráfego entre o cluster K8s e os componentes stateful no host (PG, Kafka, MinIO, Vault Transit), (c) tráfego cross-DC.

## Como atualizar

Sempre que um chart, RUNBOOK ou ADR introduzir um fluxo novo cross-cluster ou cross-DC, **adicionar uma linha aqui no mesmo PR**. A DIRSI deve ser notificada antes do PR ir para a fase de sanidade pela primeira vez (não precisa ser em cada lab).

Cada linha referencia o documento que originou a decisão (ADR, RUNBOOK ou chart README), para que a DIRSI possa rastrear o "porquê" sem depender só da tabela.

## Matriz

| # | Origem | Destino | Porta/Protocolo | Direção | Propósito | Fase em que aparece | Referência |
|---|--------|---------|------------------|---------|-----------|---------------------|------------|
| 1 | Pods Vault em `*-sp1` | Vault Transit em `*-pa1` | Lab: 30200/tcp (NodePort); prod: 443/tcp (HTTPS público) | SP1 → PA1 | Auto-unseal cross-cluster via `seal "transit"`. Cada Pod do Vault em SP1 chama o endpoint Transit em PA1 para descriptografar a chave-mestra ao iniciar. | Lab em diante | [ADR-007](adrs/ADR-007-vault-ha-storage-unseal.md) |
| 2 | Pods Vault em `*-sp2` | Vault Transit em `*-pa1` | Lab: 30200/tcp (NodePort); prod: 443/tcp (HTTPS público) | SP2 → PA1 | Idem item 1, a partir de SP2. | Lab em diante | [ADR-007](adrs/ADR-007-vault-ha-storage-unseal.md) |
| 3 | DIRSI/CTIC (admin) | Vault Transit em `*-pa1` | Lab: 30200/tcp (NodePort); prod: 443/tcp (HTTPS público) | Externo → PA1 | Bootstrap inicial do Transit (Shamir 5/3) e operações de DR. Acesso restrito via VPN institucional ou IngressRoute interno. | Lab em diante (manual) | [docs/RUNBOOKS.md](RUNBOOKS.md) |

> **Tráfego intra-cluster do Vault** (peers Raft em 8201/tcp dentro do mesmo K3s) é governado por NetworkPolicy do chart `platform/vault/` e não entra nesta matriz por ser local ao cluster.

## Próximos componentes (a preencher em PRs futuros)

Cada item abaixo entra com pelo menos uma linha quando a issue/chart correspondente for entregue:

- **PostgreSQL replication** (issues #10, futuras) — streaming replication entre primary e replicas distribuídos por DC.
- **Kafka KRaft** (issue #11) — quorum entre controllers e replicação entre brokers nos 3 DCs.
- **MinIO bucket replication** (issue #12) — replicação contínua entre `*-sp1`, `*-sp2` e `*-pa1`.
- **Cloudflared tunnels** (issue #25) — tráfego de saída para o tunnel Cloudflare por DC.
- **Backup destino PA1** — fluxos de backup de PG/MinIO/Vault para `pa1-backup`.
- **Observabilidade agregada em PA1** — push de métricas/logs/traces de SP1/SP2 para Loki/Tempo/Prometheus em PA1, conforme retenção definida em §9 do ARCHITECTURE.

## Histórico de mudanças

| Data | Versão | Autor | Mudança |
|------|--------|-------|---------|
| 2026-05-03 | 0.1 | Jeferson Ferreira | Criação inicial com fluxos do Vault (ADR-007). |
