# uniplus-infra

> Infraestrutura como código (IaC) da plataforma **Uni+** — Universidade Federal do Sul e Sudeste do Pará (UNIFESSPA).

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Status](https://img.shields.io/badge/status-em%20constru%C3%A7%C3%A3o-yellow)
![Kubernetes](https://img.shields.io/badge/kubernetes-1.30%2B-blue)
![Helm](https://img.shields.io/badge/helm-3.x-blue)
![ArgoCD](https://img.shields.io/badge/argocd-2.x-blue)

## Sobre

Este repositório contém todos os manifests, charts Helm, scripts e documentação operacional necessários para provisionar e operar a plataforma **Uni+** no ambiente `uniplus-prd`.

A plataforma Uni+ é o sistema institucional unificado da UNIFESSPA para processos seletivos, ingresso e portal acadêmico, composta por três módulos integrados (Portal, Seleção e Ingresso) com autenticação federada via Gov.br.

## Estrutura do repositório

```
uniplus-infra/
├── apps/                       # Charts Helm das aplicações
├── platform/                   # Componentes de plataforma (Traefik, Vault, External Secrets, KES, observabilidade...)
├── environments/
│   └── uniplus-prd/            # Values de validação dos charts no CI
├── docs/                       # RUNBOOKS, caminhos do Vault, reprodutibilidade, ADRs
├── scripts/
│   └── servicos-no-host/       # Scripts das duas VMs (infraestrutura e aplicação)
└── .github/                    # CI
```

## Princípios arquiteturais

**1. GitOps como fonte única de verdade.** Todo o estado declarativo da plataforma reside neste repositório. O ArgoCD em cada cluster reconcilia continuamente o estado real com o desejado.

**2. Duas VMs.** A aplicação roda em K3s numa VM; PostgreSQL, Redis, MinIO, Kafka e RabbitMQ rodam na outra, em containers sob systemd, só com TLS.

**3. Componentes stateful fora do Kubernetes.** Backup, restore e diagnóstico independem da saúde do K8s.

**4. Segredos nunca em código.** Toda credencial reside no Vault, com um KV por sistema e ambiente, e é injetada nos pods pelo External Secrets Operator. Os manifests contêm apenas referências (`ExternalSecret`).

**5. Atualização manual.** A produção só recebe a versão que já roda em homologação, gravada no repositório de implantação, e só muda quando um Maintainer sincroniza no ArgoCD.

## Documentação

| Documento | Descrição |
|-----------|-----------|
| [docs/RUNBOOKS.md](docs/RUNBOOKS.md) | Procedimentos operacionais (bootstrap, atualização, certificado) |
| [docs/vault-caminhos.md](docs/vault-caminhos.md) | KV por sistema e ambiente e mapa de caminhos |
| [docs/REPRODUCIBILITY.md](docs/REPRODUCIBILITY.md) | O que é codificado e o que é manual |
| [docs/adrs/](docs/adrs/) | Architecture Decision Records  |
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
| Entrada HTTP/TLS | Traefik IngressRoute + cert-manager (Let's Encrypt) | 3.x |
| Observabilidade — métricas | Prometheus + Grafana | 2.x / 11.x |
| Observabilidade — logs | Loki + Promtail | 3.x |
| Observabilidade — traces | Tempo + OpenTelemetry Collector | 2.x |
| Banco relacional | PostgreSQL + Patroni + PgBouncer | 16+ |
| Mensageria | Apache Kafka (KRaft mode) | 3.7+ |
| Storage de objetos | MinIO (modo distribuído) | latest |
| Cache | Valkey / Redis OSS-compatible + Sentinel | a definir |
| Antimalware | ClamAV | latest |
| IdP federado | Keycloak | 25+ |

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
