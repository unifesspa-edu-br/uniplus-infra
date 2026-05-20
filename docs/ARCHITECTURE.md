# Arquitetura da Plataforma Uni+

> Visão arquitetural completa do sistema Uni+ — UNIFESSPA / CTIC.

## Sumário

- [1. Contexto](#1-contexto)
- [2. Princípios Arquiteturais](#2-princípios-arquiteturais)
- [3. Visão de Contexto (C4 Nível 1)](#3-visão-de-contexto-c4-nível-1)
- [4. Visão de Container (C4 Nível 2)](#4-visão-de-container-c4-nível-2)
- [5. Topologia Física (C4 Deployment)](#5-topologia-física-c4-deployment)
- [5.5 Topologias suportadas](#55-topologias-suportadas)
- [6. Componentes Internos (C4 Nível 3)](#6-componentes-internos-c4-nível-3)
- [7. Fluxos Principais](#7-fluxos-principais)
- [8. Decisões Arquiteturais](#8-decisões-arquiteturais)
- [9. Estratégia por Componente](#9-estratégia-por-componente)
- [10. Mapeamento de Componentes](#10-mapeamento-de-componentes)

## 1. Contexto

A plataforma **Uni+** é o sistema institucional unificado da UNIFESSPA para processos seletivos, ingresso e portal acadêmico. Substitui sistemas legados fragmentados, oferecendo experiência única ao candidato, aluno, servidor e gestor, com integração ao login único do Governo Federal (Gov.br).

### 1.1 Módulos funcionais

| Módulo | Responsabilidade | Domínio público |
|--------|-----------------|-----------------|
| **Portal** | Conteúdo institucional, perfis, notificações | `uniplus.unifesspa.edu.br/portal` |
| **Seleção** | Editais, inscrições, classificação, recursos | `uniplus.unifesspa.edu.br/selecao` |
| **Ingresso** | Matrícula inicial, vínculo acadêmico | `uniplus.unifesspa.edu.br/ingresso` |

### 1.2 Requisitos não-funcionais

| Categoria | Requisito |
|-----------|-----------|
| Disponibilidade | ≥ 99,9% mensal (alvo combinado 99,95%) |
| Carga | 500 a 2.000 usuários simultâneos em pico de edital |
| RPO | ≤ 5 minutos |
| RTO | ≤ 1 hora |
| Segurança | Conformidade LGPD, criptografia em trânsito e repouso |
| Soberania | Hospedagem nacional, backup em infra UNIFESSPA |
| Identidade | Gov.br como provedor único, com 2FA obrigatório |

## 2. Princípios Arquiteturais

### 2.1 Microsserviços com comunicação assíncrona

A integração entre módulos ocorre via **eventos de domínio** publicados no Apache Kafka. Cada API tem seu próprio banco de dados (princípio Database per Service do DDD), eliminando acoplamento por compartilhamento de estado.

**Implicação:** falha em um módulo não derruba os demais. Eventos podem ser reprocessados após restauração.

### 2.2 Independência operacional entre datacenters

> **Status (2026-05-19):** este princípio descreve a arquitetura-alvo. Hoje a plataforma opera no ambiente `standalone-compact` — 1 cluster K3s + 1 data-host externo em OCI GRU (ver [§5.5](#55-topologias-suportadas)). O modelo dos 3 DCs (SP1+SP2+PA1) é a topologia de referência institucional, mas só será adotada quando houver acordo formal com EVEO e DIRSI sobre IPSEC/Palo Alto/roteamento. Os ADRs do bloco 001/007 que descreviam o 3-DC puro foram marcados como Superseded por [ADR-008](adrs/ADR-008-topologia-standalone.md).

A plataforma é modelada (futuro) como **3 DCs lógicos**:

- `SP1`: datacenter externo EVEO Cotia, ativo para tráfego de usuário.
- `SP2`: datacenter externo EVEO Osasco, ativo para tráfego de usuário.
- `PA1`: datacenter institucional da UNIFESSPA em Marabá, origem institucional de identidade, backup/DR, retenção e funções de consenso quando aplicável.

`SP1` e `SP2` mantêm clusters Kubernetes independentes. `PA1` não é um simples witness: é um DC institucional com serviços próprios. Não há cluster K8s estendido entre DCs.

**Implicação:** a perda de qualquer 1 DC deve manter o serviço principal disponível. A indisponibilidade de `PA1` degrada sincronização institucional, backup e retenção, mas não deve interromper o atendimento normal em `SP1` e `SP2`.

### 2.3 Componentes stateful pesados fora do Kubernetes

**PostgreSQL, Kafka e MinIO** operam como containers gerenciados por systemd diretamente no host Linux, com volumes em partições LVM dedicadas no NVMe local.

**Justificativa:**

- Acesso direto ao storage NVMe sem camadas intermediárias (CSI driver overhead)
- Backup, restore e troubleshooting independem da saúde do K8s
- Menor superfície de complexidade operacional
- Recovery independente em caso de falha do cluster

### 2.4 GitOps e infraestrutura como código

Todo o estado declarativo da plataforma reside no Git, aplicado via ArgoCD em ambos os clusters. Mudanças manuais (`kubectl apply`, edits via UI) são desencorajadas e reconciliadas pelo ArgoCD.

### 2.5 Soberania institucional dos dados

Backups, LDAP institucional, origem OIDC institucional (`pa1-oidc-source`) e configurações sensíveis permanecem sob controle da UNIFESSPA em `PA1`. Provedores externos atuam no caminho de tráfego e execução dos serviços, nunca como detentores únicos dos dados.

### 2.6 Ativo-ativo no nível da plataforma

O Uni+ adota ativo-ativo **no nível da plataforma**, não multi-master artificial em todos os produtos.

**Decisão:** para cada componente, usamos o mecanismo nativo de HA, replicação, sincronização ou quorum suportado pelo produto. Onde multi-writer não é suportado de forma limpa, distribuímos responsabilidade, usamos failover controlado e mantemos todos os DCs com papel ativo no sistema.

**Consequência:** a disponibilidade do usuário depende de `SP1` e `SP2` conseguirem atender sem chamada síncrona obrigatória ao `PA1`. Quando `PA1` retorna, processos de sincronização, backlog de backup, replicação e equalização devem prosseguir até convergir.

## 3. Visão de Contexto (C4 Nível 1)

![Diagrama de Contexto](images/01-uniplus-context.png)

> Diagrama de Contexto — Sistema Uni+ e seus relacionamentos com atores e sistemas externos.

### 3.1 Atores

| Ator | Descrição |
|------|-----------|
| **Candidato** | Pessoa interessada em ingressar via processo seletivo |
| **Aluno** | Estudante matriculado |
| **Servidor** | Docente ou técnico-administrativo |
| **Gestor Acadêmico** | Coordenador de processos seletivos e ingresso |

### 3.2 Sistemas externos

| Sistema | Responsabilidade |
|---------|-----------------|
| **Gov.br** | Provedor de identidade do Governo Federal (login único + 2FA) |
| **pa1-oidc-source** | Origem institucional de metadados de identidade e integração LDAP no PA1; implementação atual usa Keycloak |
| **LDAP/AD UNIFESSPA** | Diretório institucional de alunos e servidores |
| **pa1-object-storage** | Storage de objetos institucional para retenção, replicação e DR |
| **Backup UNIFESSPA** | Infraestrutura interna de backup e DR |
| **Servidor de E-mail** | Envio de notificações e comunicados |

## 4. Visão de Container (C4 Nível 2)

![Diagrama de Container](images/02-uniplus-container.png)

> Diagrama de Container — Aplicações, bancos de dados e serviços internos do Uni+.

### 4.1 Camada de borda

- **Entrada HTTP/TLS de lab**: mecanismo provisório para expor a PoC. Não valida WAF, DNS institucional, IPSEC, firewall ou inspeção TLS.
- **Traefik**: API Gateway + Ingress Controller dentro de cada cluster K8s. Roteia por path para os componentes corretos.

### 4.2 Camada de apresentação

Três frontends Angular independentes (Portal, Seleção, Ingresso), servidos por Nginx em containers Kubernetes. Cada frontend acessa sua respectiva API via Traefik.

### 4.3 Camada de aplicação

- **3 APIs .NET 10**: Portal, Seleção, Ingresso — uma por módulo, com SharedKernel como library compartilhada.
- **ClamAV Scanner**: worker assíncrono de análise antimalware, consumer de eventos Kafka.
- **OIDC local**: serviço de autenticação em cada DC. A implementação atual usa Keycloak, mas o contrato arquitetural é OIDC.

### 4.4 Camada de mensageria e cache

- **Kafka KRaft**: bus de eventos de domínio, com quorum e replicação nativos quando a latência entre DCs permitir.
- **Redis/Valkey**: cache local por DC para dados descartáveis e sessões transientes não críticas.

### 4.5 Camada de dados

- **3 PostgreSQL 16** (uma por API): bancos `uniplus_portal`, `uniplus_selecao`, `uniplus_ingresso`.
- **MinIO Distribuído**: storage de objetos com 3 buckets (`quarentena/`, `aprovado/`, `bloqueado/`).

## 5. Topologia Física (C4 Deployment)

![Diagrama de Deployment](images/03-uniplus-deployment.png)

> Diagrama de Deployment — Topologia física entre entrada de lab, EVEO (`SP1`/`SP2`) e UNIFESSPA (`PA1`).

### 5.1 EVEO — Datacenter Tier III

Dois servidores físicos dedicados, distribuídos entre as zonas de disponibilidade SP1 (Cotia) e SP2 (Osasco):

| Especificação | Valor |
|---------------|-------|
| Processador | 2× Intel Xeon Gold 6138 — 40 cores / 80 threads |
| RAM | 96 GB DDR4 ECC |
| Storage | 2× 2 TB NVMe em RAID 1 |
| Rede | 1 Gbps tráfego ilimitado, IPv4 /29, IPv6 /56 |
| SO | Ubuntu Server 24.04 LTS |

Conectados por **link L2L privado de 500 Mbps**, redundante e com latência sub-milissegundo.

### 5.2 PA1 — UNIFESSPA Marabá-PA

`PA1` é o DC institucional da UNIFESSPA. Ele abriga serviços de soberania e recuperação, mas não deve ser ponto único de falha para o atendimento normal:

- **Palo Alto**: NGFW que termina os túneis IPSEC dos DCs EVEO
- **pa1-oidc-source**: origem institucional de identidade/OIDC; implementação atual usa Keycloak
- **LDAP/AD**: diretório institucional, existente apenas em `PA1`
- **pa1-object-storage**: storage institucional para retenção e replicação de objetos
- **pa1-backup**: destino real de pgBackRest, snapshots e artefatos de recuperação
- **pa1-consensus-witness**: função opcional de quorum para componentes que usam consenso externo, como Patroni/etcd

### 5.3 Entrada HTTP/TLS de laboratório

Atua apenas como forma provisória de acesso externo à PoC. A arquitetura de produção para borda, DNS, WAF, IPSEC, firewall e inspeção TLS será definida por infraestrutura/rede sobre a réplica mínima de produção.

### 5.4 Distribuição de primaries de banco

Para balancear carga de escrita entre os DCs, os primaries dos bancos são distribuídos:

| Banco | Primary em | Replica em |
|-------|-----------|-----------|
| `uniplus_portal` | SP1 | SP2 |
| `uniplus_selecao` | SP2 | SP1 |
| `uniplus_ingresso` | SP1 | SP2 |

`PA1` participa da recuperabilidade e pode manter réplicas/backup conforme o componente, mas não recebe primary operacional obrigatório para tráfego de usuário.

### 5.5 Topologias suportadas

A plataforma é deployable em **duas topologias** distintas — não duas configurações da mesma topologia, e sim modelos com objetivos operacionais diferentes. A escolha entre elas é orientada pelo SLA pretendido, não por preferência técnica.

#### 5.5.1 3-DC (SP1 + SP2 + PA1) — modelo de produção plena

Topologia detalhada nas seções §5.1–5.4. Resumo dos drivers:

- **Atendimento ativo-ativo** entre SP1 e SP2 com link L2L de 500 Mbps.
- **PA1** carrega responsabilidades institucionais (LDAP/AD, OIDC source institucional, retenção de backup, witness opcional). Pode ficar fora algumas horas sem derrubar o atendimento.
- **HA por componente**: Patroni para Postgres, KRaft para Kafka, modo distribuído do MinIO, Vault em modo HA com Raft, etc.
- **Falha completa de um DC**: o outro continua servindo o tráfego com degradação aceitável (latência, throughput de write em primaries movidos).

**Quando usar:** produção, HML que precisa exercitar o modelo de DR, certificação institucional.

**Custo:** 3 racks/locações, link L2L privado, redundância de hardware, time de operação 24×7.

#### 5.5.2 Standalone (monolocal) — modelo de validação institucional

Topologia descrita em [ADR-008](adrs/ADR-008-topologia-standalone.md). Resumo:

- **Single-site monolocal** — duas VMs (`k8s-host`, `data-host`) coabitam o mesmo provedor (lab, OCI Always Free, ou laboratório institucional).
- **Sem HA inter-DC** — a topologia não pretende sobreviver a falha de site. Single-node K3s + Postgres 18 + Kafka KRaft + MinIO single-node + Vault Shamir 1-de-1.
- **GitOps end-to-end preservado** — chart layout, ArgoCD, ExternalSecrets, ESO continuam idênticos ao 3-DC. O delta é nos `environments/standalone/values.yaml` (1 réplica, sem witness, paths de storage local, etc.).
- **Acesso externo via Cloudflare Tunnel** — sem dependência de IP público nem de NAT/DNS institucional. Smoke E2E completo executável (PR #181).
- **Provisioning provider-agnostic** — VMs de qualquer provedor (OCI, lab on-prem, VMs em estação de trabalho) bastam ter Ubuntu 24.04 + kernel atualizado + IP roteável entre as duas VMs.

**Quando usar:**

- Validação técnica antes de provisionar 3-DC (smoke E2E, integração ponta-a-ponta).
- Workshops, treinamento interno, demonstração para gestão.
- Disaster recovery exploration (subir uma cópia funcional num provedor alternativo em horas).
- Ambientes institucionais que aceitam SLA single-site (ex.: secretarias internas, painéis administrativos).

**O que não cobre:**

- Falha de site (rede, energia, hardware) → indisponibilidade total até reparo.
- Volume de produção plena Uni+ (~20k candidatos/processo) → standalone tem limites de throughput nativos do single-node.
- Compliance institucional que exija redundância geográfica.

**Custo:** 2 VMs (~12 vCPU + 24 GB RAM + 200 GB) + Cloudflare Tunnel (gratuito até limites). Operável por 1 pessoa.

#### 5.5.3 Como o repositório suporta as duas

| Aspecto | 3-DC (referência futura) | Standalone (em uso 2026-05-19) |
|---|---|---|
| `apps/` charts | mesmos | mesmos |
| `platform/` charts | mesmos | mesmos |
| `data/` (Postgres/Kafka/MinIO/Redis fora-do-K8s) | binários iguais, configs HA | binários iguais, configs single-node |
| `environments/` overrides | a derivar de standalone-compact quando 3-DC for revivido | `standalone-compact/` |
| `argocd/applicationset.yaml` | mesmo (multi-cluster) | mesmo (single-cluster, gera só Apps de standalone-compact) |
| `scripts/bootstrap-{role}.sh` | (não implementado) | `bootstrap-standalone.sh` |
| ADRs específicas | ADRs 001–007 (superseded em 2026-05-19) | [ADR-008](adrs/ADR-008-topologia-standalone.md), [ADR-010](adrs/ADR-010-keycloak-config-cli-realm-reconcile.md), e demais |

**Princípio de divergência mínima:** valores divergem apenas em `environments/<env>/values.yaml`. Charts não trazem código condicional `{{- if eq .Values.topology "standalone" -}}` — a topologia é uma propriedade do environment, não do chart.

> Excecções pontuais (ex.: `keycloak.realmReconcile.enabled` ligado em standalone, desligado em prod até o smoke validar; `traefik.updateStrategy.type=Recreate` necessário em single-node por HostPort conflict) ficam em values.yaml documentadas inline e em ADR. Não há flag global de "topologia".

> **Histórico:** até 2026-05-19 o repositório também trazia `environments/lab-{sp1,sp2,pa1}/`, `environments/prod-{sp1,sp2,pa1}/`, `environments/standalone/`, `scripts/bootstrap-lab.sh` e `scripts/teardown-lab.sh`. Esses arquivos foram removidos por nunca terem sido provisionados (ver `CHANGELOG.md`). Quando o modelo 3-DC for revivido, derivar do `standalone-compact` (mais maduro).

## 6. Componentes Internos (C4 Nível 3)

![Diagrama de Componentes — API Seleção](images/04-uniplus-component-api-selecao.png)

> Diagrama de Componentes — Estrutura interna da API Seleção (representativa das demais).

As 3 APIs do Uni+ seguem padrão Clean Architecture com Domain-Driven Design:

- **Controllers** (ASP.NET Core MVC): endpoints REST
- **Authorization Middleware**: validação de JWT (RS256) via JWKS
- **Application Services**: casos de uso explícitos
- **Domain Layer**: entidades, agregados, value objects, regras invariantes
- **Persistence**: EF Core 8, repositórios, Unit of Work
- **Event Publisher / Consumer**: integração via Kafka (MassTransit)
- **S3 Client**: geração de presigned URLs para MinIO
- **Cache Service**: read-through sobre Redis
- **Observability**: instrumentação OpenTelemetry

A `SharedKernel` (referenciada como library) contém: tipos comuns (`Result<T>`, value objects), contratos de eventos Kafka, abstrações de infraestrutura, validações compartilhadas.

## 7. Fluxos Principais

### 7.1 Upload de documento com análise antimalware

![Fluxo de Upload](images/05-uniplus-sequence-upload-clamav-simples.png)

> Visão macro do fluxo de upload de documentos com análise antimalware assíncrona.

**Resumo:** o usuário faz upload diretamente ao MinIO via presigned URL gerada pela API. Um evento Kafka aciona o ClamAV Scanner que analisa o arquivo de forma assíncrona e move para `aprovado/` ou `bloqueado/` conforme o resultado. O usuário é notificado via WebSocket.

**Detalhes técnicos completos:** veja [docs/RUNBOOKS.md](RUNBOOKS.md#fluxo-de-upload).

### 7.2 Autenticação Gov.br via OIDC federado

![Fluxo de Autenticação](images/06-uniplus-sequence-auth-govbr-simples.png)

> Visão macro da autenticação Gov.br via OIDC federado. A implementação atual usa Keycloak, mas o contrato documentado é OIDC.

**Resumo:** o frontend inicia OIDC contra o endpoint lógico de autenticação do Uni+. `SP1`, `SP2` e `PA1` executam serviço OIDC operacional, com contrato comum para o realm `unifesspa`. O login principal usa gov.br; o LDAP institucional existe apenas em `PA1` e alimenta sincronização institucional, mas não deve ser dependência síncrona obrigatória para o atendimento normal.

Se `PA1` ficar indisponível, `SP1` e `SP2` continuam aptos a atender o fluxo principal de login via gov.br/OIDC. A sincronização institucional e eventuais atualizações oriundas do LDAP ficam pendentes até o retorno de `PA1`.

## 8. Decisões Arquiteturais

As decisões arquiteturais da infraestrutura são formalizadas como ADRs (Architectural Decision Records) e podem ser encontradas em [docs/adrs/](adrs/README.md).

### Resumo das ADRs de Infraestrutura

- **[ADR-001: Três DCs lógicos e clusters K8s independentes](adrs/ADR-001-tres-dcs-logicos-e-clusters-k8s-independentes.md)**: Opção por clusters independentes para isolamento de falha e autonomia operacional.
- **[ADR-002: Componentes stateful pesados fora do Kubernetes](adrs/ADR-002-componentes-stateful-pesados-fora-do-kubernetes.md)**: Bancos e mensageria no host (em containers via systemd) para performance e simplificação de DR.
- **[ADR-003: Gov.br federado via OIDC institucional](adrs/ADR-003-govbr-federado-via-oidc-institucional.md)**: Uso de OIDC institucional federado com Gov.br para soberania de identidade.
- **[ADR-004: Borda externa fora do escopo da PoC](adrs/ADR-004-borda-externa-fora-do-escopo-da-poc.md)**: Definição de WAF/DNS delegada à infra de rede após validação da PoC.
- **[ADR-005: Stateful em containers via systemd](adrs/ADR-005-stateful-em-containers-via-systemd.md)**: Empacotamento de serviços de dados em containers fora do K8s para portabilidade.
- **[ADR-006: GitOps com ArgoCD](adrs/ADR-006-gitops-com-argocd.md)**: Uso de ArgoCD para garantir estado declarativo e evitar drift entre clusters.
- **[ADR-007: Vault HA com auto-unseal Transit centralizado em PA1](adrs/ADR-007-vault-ha-storage-unseal.md)**: Vault OSS com 3 réplicas Raft por cluster SP1/SP2 e Vault Transit dedicado em PA1 para auto-unseal cross-cluster, mantendo soberania institucional.

Para decisões futuras e histórico completo, consulte o [diretório de ADRs](adrs/README.md).

## 9. Estratégia por Componente

Esta seção define o mecanismo de redundância aceito para cada família de serviço. O objetivo é manter ativo-ativo no nível da plataforma sem forçar modos que o produto não suporta de forma limpa.

| Componente | Estratégia |
|------------|------------|
| OIDC / identidade | Serviço OIDC operacional em `SP1`, `SP2` e `PA1`, com contrato lógico comum. `pa1-oidc-source` concentra a origem institucional e integração LDAP; login principal via gov.br/OIDC deve continuar em `SP1`/`SP2` com `PA1` fora. |
| PostgreSQL | Ativo-ativo por distribuição de primaries entre módulos, réplicas por DC, failover controlado e `pa1-backup`. Não há multi-master artificial. |
| Kafka | Quorum e replicação nativos do KRaft quando a latência permitir. A distribuição de controllers/brokers deve tolerar a perda de qualquer 1 DC no cenário alvo. |
| MinIO / objetos | Replicação/site ou bucket replication nativa entre `SP1`, `SP2` e `PA1`, com chaves de objeto imutáveis sempre que possível. |
| Cache Redis/Valkey | Cache local por DC, descartável e reconstruível. Não participa de consenso global nem deve armazenar estado autoritativo. |
| Observabilidade | Coleta local por DC e agregação/retenção conforme desenho. Queda de `PA1` não deve impedir métricas/logs/traces locais em `SP1` e `SP2`. |
| Backup / DR | `PA1` é destino real de backup. Se `PA1` ficar indisponível, `SP1` e `SP2` mantêm spool/backlog local e sincronizam quando `PA1` retornar. |
| Vault / secrets | HashiCorp Vault OSS em HA Raft (3 réplicas) por cluster `SP1` e `SP2`, independentes. Vault Transit dedicado em `PA1` provê auto-unseal cross-cluster via `seal "transit"`. Topologia idêntica desde lab até prod, variando apenas escala. Detalhes em [ADR-007](adrs/ADR-007-vault-ha-storage-unseal.md). |
| StorageClass | Cada cluster tem **uma StorageClass nomeada explicitamente por tier**: `lab-local-nvme`, `san-local-nvme`, `hml-local-nvme`, `prod-local-nvme`. Provisioner padrão `rancher.io/local-path` (K3s) — em hml/prod a DIRSI confirma se mantém local-path ou substitui por CSI driver dedicado. Nome estável minimiza churn nos values dos demais charts. Chart `platform/storage/` cria a SC; PVCs de Vault, Postgres-on-K8s e observability referenciam por nome. |

## 10. Mapeamento de Componentes

### 10.1 Componentes no Kubernetes (por DC)

| Serviço | Réplicas | CPU req → limit | RAM req → limit |
|---------|----------|-----------------|-----------------|
| Frontend Portal | 2 | 100m → 500m | 128 MB → 256 MB |
| Frontend Seleção | 2 | 100m → 500m | 128 MB → 256 MB |
| Frontend Ingresso | 2 | 100m → 500m | 128 MB → 256 MB |
| API Portal | 2 | 500m → 2000m | 512 MB → 2 GB |
| API Seleção | 2 | 500m → 2000m | 512 MB → 2 GB |
| API Ingresso | 2 | 500m → 2000m | 512 MB → 2 GB |
| ClamAV Scanner | 1-2 | 500m → 4000m | 2 GB → 4 GB |
| Traefik | 2 | 200m → 1000m | 256 MB → 512 MB |
| Serviço OIDC (Keycloak atual) | 2 | 500m → 2000m | 1 GB → 2 GB |
| Redis | 2 | 200m → 1000m | 1 GB → 4 GB |
| ArgoCD | 1 | 200m → 1000m | 512 MB → 2 GB |
| Vault | 1 (HA: 3) | 200m → 500m | 256 MB → 512 MB |
| Prometheus | 1 | 500m → 2000m | 2 GB → 4 GB |
| Grafana + Loki + Tempo + OTel | — | ~1 vCPU | ~6 GB |

### 10.2 Componentes fora do Kubernetes (por DC)

| Serviço | CPU dedicada | RAM dedicada | Disco dedicado |
|---------|-------------|--------------|----------------|
| PostgreSQL × 3 | 12 threads | 24 GB | 400 GB |
| Kafka broker | 6 threads | 8 GB | 300 GB |
| MinIO node | 4 threads | 6 GB | 800 GB |
| etcd / função de consenso | compartilhada | 256 MB | 5 GB |

### 10.3 Distribuição de recursos

| Camada | vCPU | RAM | Disco | % do total |
|--------|------|-----|-------|------------|
| Sistema operacional | 4 | 4 GB | 30 GB | 5% / 4% |
| PostgreSQL × 3 | 12 | 24 GB | 400 GB | 15% / 25% |
| Kafka | 6 | 8 GB | 300 GB | 8% / 8% |
| MinIO | 4 | 6 GB | 800 GB | 5% / 6% |
| Cluster K8s | 50 | 50 GB | 400 GB | 63% / 52% |
| Buffer | 4 | 4 GB | 70 GB | 5% / 4% |
| **Total** | **80** | **96 GB** | **2 TB** | **100%** |

---

## Anexos

- [RUNBOOKS.md](RUNBOOKS.md) — Procedimentos operacionais detalhados (bootstrap standalone, failover 3-DC histórico)
- [adrs/](adrs/) — Architecture Decision Records (ADR-008+ vigentes)
- [validacao/](validacao/) — Relatórios de validação executadas

## Histórico de versões

| Versão | Data | Autor | Mudanças |
|--------|------|-------|----------|
| 1.0 | Abr/2026 | Jeferson Ferreira | Versão inicial baseada no DT-UNIPLUS-001 |
| 1.1 | 2026-05-19 | Jeferson Ferreira | §2.2 marcada como referência futura; §5.5.3 atualizada para standalone-compact; remoção de refs a VALIDATION-PLAN/SETUP/network-matrix |

---

*Documento mantido pelo CTIC/UNIFESSPA. Contribuições via Pull Request em [github.com/unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra).*
