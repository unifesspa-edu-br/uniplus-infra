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

## Estrutura do repositório

```
uniplus-infra/
├── apps/                       # Charts Helm das aplicações Uni+
│   ├── uniplus-web/            # Frontend Angular Nx (3 apps internas)
│   ├── uniplus-api-portal/     # API .NET 10 — módulo Portal
│   ├── uniplus-api-selecao/    # API .NET 10 — módulo Seleção
│   ├── uniplus-api-ingresso/   # API .NET 10 — módulo Ingresso
│   ├── clamav-scanner/         # Worker antimalware (consumer Kafka)
│   └── keycloak-replica/       # Réplica do Keycloak institucional
├── platform/                   # Componentes de plataforma (infra do K8s)
│   ├── traefik/                # API Gateway + Ingress Controller
│   ├── argocd/                 # GitOps controller
│   ├── vault/                  # Gestão de secrets
│   ├── external-secrets/       # Sync Vault → K8s Secrets
│   ├── cert-manager/           # Provisionamento TLS automático
│   ├── cloudflared/            # Cloudflare Tunnel (borda externa)
│   └── observability/          # Prometheus, Grafana, Loki, Tempo, OTel
├── data/                       # Componentes stateful (fora do K8s)
│   ├── postgres/               # 3 instâncias + Patroni + PgBouncer
│   ├── kafka/                  # Cluster KRaft
│   ├── minio/                  # Storage de objetos distribuído
│   └── redis/                  # Cache distribuído
├── environments/               # Overrides por ambiente
│   ├── lab-sp1/                # Laboratório local — máquina principal
│   ├── lab-sp2/                # Laboratório local — máquina secundária
│   ├── lab-witness/            # Laboratório local — UNIFESSPA simulada
│   ├── prod-sp1/               # Produção — EVEO Cotia
│   └── prod-sp2/               # Produção — EVEO Osasco
├── argocd/                     # Bootstrap GitOps (ApplicationSet)
├── docs/                       # Documentação operacional
│   ├── ARCHITECTURE.md         # Visão arquitetural da plataforma
│   ├── VALIDATION-PLAN.md      # Plano de validação arquitetural
│   ├── SETUP.md                # Setup de máquinas do laboratório
│   ├── RUNBOOKS.md             # Procedimentos operacionais
│   └── images/                 # Diagramas C4 e ilustrações
├── scripts/                    # Scripts de automação
│   ├── bootstrap-lab.sh        # Provisiona laboratório do zero
│   ├── teardown-lab.sh         # Limpa o laboratório
│   └── validate-cluster.sh     # Valida saúde do cluster
└── .github/                    # CI/CD workflows
```

## Princípios arquiteturais

**1. GitOps como fonte única de verdade.** Todo o estado declarativo da plataforma reside neste repositório. O ArgoCD em cada cluster reconcilia continuamente o estado real com o desejado.

**2. Mesma stack, ambientes diferentes.** Os mesmos charts Helm rodam em laboratório e produção. Apenas valores específicos por ambiente diferem (réplicas, recursos, hostnames, secrets).

**3. Componentes stateful fora do Kubernetes.** PostgreSQL, Kafka e MinIO operam como containers gerenciados por systemd diretamente no host Linux, garantindo performance previsível e operação simplificada (backup, restore, troubleshooting).

**4. Secrets nunca em código.** Toda credencial, chave ou token reside no HashiCorp Vault e é injetada nos pods via External Secrets Operator. Os manifests do Git contém apenas referências (`ExternalSecret`).

**5. Soberania institucional.** Backups, identidade institucional e configurações sensíveis permanecem sob controle da UNIFESSPA. Provedores externos (EVEO, Cloudflare) atuam apenas no caminho de tráfego, nunca como detentores de dados.

## Documentação

| Documento | Descrição |
|-----------|-----------|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Visão arquitetural completa, com diagramas C4 |
| [docs/VALIDATION-PLAN.md](docs/VALIDATION-PLAN.md) | Plano de validação arquitetural em laboratório local |
| [docs/SETUP.md](docs/SETUP.md) | Passo-a-passo de setup das máquinas do laboratório |
| [docs/RUNBOOKS.md](docs/RUNBOOKS.md) | Procedimentos operacionais (failover, backup, etc.) |

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
| Borda externa | Cloudflare Tunnel | latest |
| Observabilidade — métricas | Prometheus + Grafana | 2.x / 11.x |
| Observabilidade — logs | Loki + Promtail | 3.x |
| Observabilidade — traces | Tempo + OpenTelemetry Collector | 2.x |
| Banco relacional | PostgreSQL + Patroni + PgBouncer | 16+ |
| Mensageria | Apache Kafka (KRaft mode) | 3.7+ |
| Storage de objetos | MinIO (modo distribuído) | latest |
| Cache | Redis + Redis Sentinel | 7.x |
| Antimalware | ClamAV | latest |
| IdP federado | Keycloak | 25+ |

## Status atual

| Componente | Lab SP1 | Lab SP2 | Lab Witness | Prod SP1 | Prod SP2 |
|------------|---------|---------|-------------|----------|----------|
| Provisionamento | 🟡 em planejamento | 🟡 em planejamento | 🟡 em planejamento | ⚪ aguardando contrato EVEO | ⚪ aguardando contrato EVEO |
| ArgoCD | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ |
| Vault | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ |
| Aplicações Uni+ | ⚪ | ⚪ | ⚪ | ⚪ | ⚪ |

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
