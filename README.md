# uniplus-infra

> Infraestrutura como código (IaC) da plataforma **Uni+** — Universidade Federal do Sul e Sudeste do Pará (UNIFESSPA).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-em%20constru%C3%A7%C3%A3o-yellow)
![Kubernetes](https://img.shields.io/badge/kubernetes-1.30%2B-blue)
![Helm](https://img.shields.io/badge/helm-3.x-blue)
![ArgoCD](https://img.shields.io/badge/argocd-2.x-blue)

## Sobre

Este repositório contém todos os manifests, charts Helm, scripts e documentação operacional necessários para provisionar e operar a plataforma **Uni+** em diferentes ambientes — desde laboratório local de validação arquitetural até produção em datacenter Tier III.

A plataforma Uni+ é o sistema institucional unificado da UNIFESSPA para processos seletivos, ingresso e portal acadêmico, composta por três módulos integrados (Portal, Seleção e Ingresso) com autenticação federada via Gov.br.

### Topologias suportadas

O mesmo conjunto de charts e scripts é deployable em duas topologias distintas — escolhidas pelo SLA pretendido, não por preferência técnica. Detalhes em [docs/ARCHITECTURE.md §5.5](docs/ARCHITECTURE.md#55-topologias-suportadas).

| Topologia | Descrição | Quando usar | ADRs |
|---|---|---|---|
| **3-DC** (`SP1` + `SP2` + `PA1`) | Ativo-ativo entre EVEO Cotia/Osasco + DC institucional UNIFESSPA Marabá. HA por componente (Patroni/KRaft/MinIO distribuído). Sobrevive a falha de site. | Produção plena, HML que exercita DR, certificação institucional. | ADRs 001–007, 009 |
| **Standalone** (monolocal) | Single-site provider-agnostic (lab, OCI Always Free, on-prem). Duas VMs (`k8s-host` + `data-host`). K3s single-node + Postgres/Kafka/MinIO/Vault em modo single. Mesmos charts, divergência só em `environments/standalone/values.yaml`. | Validação técnica antes de 3-DC, smoke E2E, treinamento, DR exploration, ambientes institucionais com SLA single-site. | [ADR-008](docs/adrs/ADR-008-topologia-standalone.md), [ADR-009](docs/adrs/ADR-009-kafka-sasl-ssl-scram-standalone.md), [ADR-010](docs/adrs/ADR-010-keycloak-config-cli-realm-reconcile.md) |

## Estrutura do repositório

```
uniplus-infra/
├── apps/                       # Charts Helm das aplicações Uni+
│   ├── uniplus-web/            # Frontend Angular Nx (3 apps internas)
│   ├── uniplus-api-portal/     # API .NET 10 — módulo Portal
│   ├── uniplus-api-selecao/    # API .NET 10 — módulo Seleção
│   ├── uniplus-api-ingresso/   # API .NET 10 — módulo Ingresso
│   ├── clamav-scanner/         # Worker antimalware (consumer Kafka)
│   └── keycloak-replica/       # Serviço OIDC local (Keycloak na implementação atual)
├── platform/                   # Componentes de plataforma (infra do K8s)
│   ├── traefik/                # API Gateway + Ingress Controller
│   ├── argocd/                 # GitOps controller
│   ├── vault/                  # Gestão de secrets
│   ├── external-secrets/       # Sync Vault → K8s Secrets
│   ├── cert-manager/           # Provisionamento TLS automático
│   ├── cloudflared/            # Entrada HTTP/TLS provisória do lab
│   └── observability/          # Prometheus, Grafana, Loki, Tempo, OTel
├── data/                       # Componentes stateful (fora do K8s)
│   ├── postgres/               # 3 instâncias + Patroni + PgBouncer
│   ├── kafka/                  # Cluster KRaft
│   ├── minio/                  # Storage de objetos distribuído
│   └── redis/                  # Cache distribuído
├── environments/               # Overrides por ambiente
│   └── standalone-compact/     # Único ambiente operacional (OCI GRU, AMD E4.Flex)
├── argocd/                     # Bootstrap GitOps (ApplicationSet)
├── provisioning/oci/           # Provisionamento OpenTofu
│   └── standalone-compact/     # VMs E4.Flex em sa-saopaulo-1
├── docs/                       # Documentação operacional
│   ├── ARCHITECTURE.md         # Visão arquitetural da plataforma
│   ├── RUNBOOKS.md             # Procedimentos operacionais (standalone)
│   ├── adrs/                   # Architecture Decision Records
│   └── images/                 # Diagramas C4 e ilustrações
├── scripts/                    # Scripts de automação
│   ├── bootstrap-standalone.sh # Provisiona K3s + data services no host
│   ├── validate-cluster.sh     # Valida saúde do cluster
│   ├── smoke-*.sh              # Smokes (dashboards, encryption, metrics)
│   └── validate-standalone.sh  # Validação pós-bootstrap standalone
└── .github/                    # CI/CD workflows
```

## Princípios arquiteturais

**1. GitOps como fonte única de verdade.** Todo o estado declarativo da plataforma reside neste repositório. O ArgoCD em cada cluster reconcilia continuamente o estado real com o desejado.

**2. Topologia atual: standalone-compact.** A plataforma opera hoje em 1 cluster K3s + 1 data-host externo em OCI GRU (sa-saopaulo-1), shape E4.Flex AMD. O modelo dos 3 DCs (`SP1`+`SP2`+`PA1`) é a topologia de referência institucional para o futuro; sua adoção depende de acordo com EVEO e DIRSI. Detalhes em [docs/ARCHITECTURE.md §5.5](docs/ARCHITECTURE.md#55-topologias-suportadas).

**3. Ativo-ativo no nível da plataforma.** Cada componente usa o mecanismo nativo de HA, replicação, sincronização ou quorum suportado pelo produto. Onde multi-writer limpo não existir, distribuímos responsabilidade e usamos failover controlado, sem simular multi-master artificial.

**4. Componentes stateful fora do Kubernetes.** PostgreSQL, Kafka e MinIO operam como containers gerenciados por systemd diretamente no host Linux, garantindo performance previsível e operação simplificada (backup, restore, troubleshooting).

**5. Secrets nunca em código.** Toda credencial, chave ou token reside no cofre institucional e é injetada nos pods via External Secrets Operator. Os manifests do Git contêm apenas referências (`ExternalSecret`).

**6. Soberania institucional como meta.** No standalone-compact (atual) a soberania ainda depende do provedor OCI. Quando o modelo 3-DC for revivido, `PA1` (Marabá) hospedará LDAP institucional, OIDC source institucional e destino de backup, sem virar ponto único de falha para o atendimento.

## Documentação

| Documento | Descrição |
|-----------|-----------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Visão arquitetural completa, com diagramas C4 |
| [docs/RUNBOOKS.md](docs/RUNBOOKS.md) | Procedimentos operacionais (bootstrap, failover, backup) |
| [docs/REPRODUCIBILITY.md](docs/REPRODUCIBILITY.md) | Como recriar o ambiente do zero (recreate drill, checklist de passos manuais) |
| [docs/adrs/](docs/adrs/) | Architecture Decision Records (ADR-008+ vigentes) |
| [docs/validacao/](docs/validacao/) | Relatórios de validação executadas |

## Tecnologias e ferramentas

| Camada | Ferramenta | Versão alvo |
|--------|-----------|-------------|
| Container runtime | containerd | 1.7+ |
| Orquestração | Kubernetes (K3s) | 1.30+ |
| GitOps | ArgoCD | 2.x |
| Pacotes | Helm | 3.x |
| API Gateway / Ingress | Traefik | 3.x |
| Service mesh (futuro) | — | a definir |
| Secrets | HashiCorp Vault + ESO | 1.17+ / 0.10+ |
| Entrada HTTP/TLS de lab | cloudflared ou alternativa gratuita | latest |
| Observabilidade — métricas | Prometheus + Grafana | 2.x / 11.x |
| Observabilidade — logs | Loki + Promtail | 3.x |
| Observabilidade — traces | Tempo + OpenTelemetry Collector | 2.x |
| Banco relacional | PostgreSQL + Patroni + PgBouncer | 16+ |
| Mensageria | Apache Kafka (KRaft mode) | 3.7+ |
| Storage de objetos | MinIO (modo distribuído) | latest |
| Cache | Valkey / Redis OSS-compatible + Sentinel | a definir |
| Antimalware | ClamAV | latest |
| IdP federado | Keycloak | 25+ |

## Status atual

| Componente | Lab SP1 | Lab SP2 | Lab PA1 | Prod SP1 | Prod SP2 | Prod PA1 |
|------------|---------|---------|---------|----------|----------|----------|
| Provisionamento | 🟡 em planejamento | 🟡 em planejamento | 🟡 em planejamento | ⚪ aguardando contrato EVEO | ⚪ aguardando contrato EVEO | 🟡 institucional |
| GitOps / ArgoCD | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ |
| OIDC | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ | 🟡 fonte institucional |
| Backup / DR | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ | 🟡 destino institucional |
| Aplicações Uni+ | ⚪ | ⚪ | — | ⚪ | ⚪ | — |

🟢 operacional · 🟡 em construção · 🔴 com problemas · ⚪ não iniciado

## Contribuindo

Contribuições são bem-vindas via Pull Request. Antes de abrir um PR:

1. Abra uma Issue descrevendo a mudança proposta.
2. Aguarde alinhamento com o time CTIC/UNIFESSPA.
3. Siga o padrão de commits convencional ([Conventional Commits](https://www.conventionalcommits.org/pt-br/v1.0.0/)).
4. Garanta que `helm lint` e validação YAML passam.

Veja [CONTRIBUTING.md](CONTRIBUTING.md) para detalhes.

## Licença

Distribuído sob a [Licença MIT](LICENSE) — em consonância com os demais repositórios da organização UNIFESSPA no GitHub.

## Contato

| Tópico | Contato |
|--------|---------|
| Coordenação técnica | Jeferson Ferreira — `jeferson.ferreira@unifesspa.edu.br` |
| Issues e bugs | [GitHub Issues](https://github.com/unifesspa-edu-br/uniplus-infra/issues) |
| Time CTIC/UNIFESSPA | [ctic.unifesspa.edu.br](https://ctic.unifesspa.edu.br) |

## Repositórios relacionados

- [`uniplus-web`](https://github.com/unifesspa-edu-br/uniplus-web) — Frontend Angular Nx (Portal, Seleção, Ingresso)
- [`uniplus-api`](https://github.com/unifesspa-edu-br/uniplus-api) — Backend .NET 10 (Portal, Seleção, Ingresso, SharedKernel)

---

<div align="center">
  <em>Desenvolvido pelo CTIC — Centro de Tecnologia da Informação e Comunicação da UNIFESSPA</em>
</div>
