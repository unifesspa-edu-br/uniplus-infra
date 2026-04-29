# Plano de Validação Arquitetural — Laboratório Local

> Documento operacional que descreve a estratégia, topologia e cenários de validação da arquitetura Uni+ em laboratório local antes da implantação em produção.

| Documento | Versão | Data | Status |
|-----------|--------|------|--------|
| Plano de Validação Arquitetural | 1.0 | Abril/2026 | Em execução |

## Sumário

- [1. Objetivos](#1-objetivos)
- [2. Escopo](#2-escopo)
- [3. Topologia do Laboratório](#3-topologia-do-laboratório)
- [4. Mapeamento Lab ↔ Produção](#4-mapeamento-lab--produção)
- [5. Cenários de Validação](#5-cenários-de-validação)
- [6. Métricas e Critérios de Sucesso](#6-métricas-e-critérios-de-sucesso)
- [7. Limitações Declaradas](#7-limitações-declaradas)
- [8. Cronograma](#8-cronograma)
- [9. Uso dos Resultados](#9-uso-dos-resultados)

## 1. Objetivos

### 1.1 Objetivo principal

Validar empiricamente as decisões arquiteturais do Uni+ documentadas em [ARCHITECTURE.md](ARCHITECTURE.md) e no documento institucional **DT-UNIPLUS-001 — Solicitação de Análise da Divisão de Redes**, antes da contratação dos servidores em produção e da exposição da plataforma à comunidade UNIFESSPA.

### 1.2 Objetivos específicos

1. **Provar resiliência**: demonstrar que a arquitetura ativo-ativo entre dois DCs sobrevive à falha total de um deles, com perda de dados dentro do RPO acordado (≤ 5 min).
2. **Validar failover de banco**: medir o tempo real de failover do PostgreSQL via Patroni com 3 nós etcd (incluindo witness UNIFESSPA).
3. **Demonstrar prevenção de split-brain**: reproduzir cenário de partição de rede entre DCs e provar que o witness etcd previne dois primaries simultâneos.
4. **Mensurar comportamento sob carga**: simular 500-2.000 usuários simultâneos em pico de edital e medir latência/throughput.
5. **Validar fluxos críticos**: exercitar end-to-end os fluxos de upload com ClamAV e autenticação Gov.br federada.
6. **Embasar decisões pendentes**: gerar dados objetivos para subsidiar discussões com a Divisão de Redes (especialmente sobre Cloudflare e túneis IPSEC).

## 2. Escopo

### 2.1 Dentro do escopo

✅ Topologia ativo-ativo entre dois "DCs" simulados em hardware real (duas máquinas físicas separadas)
✅ Replicação de dados (PostgreSQL streaming, Kafka MirrorMaker, MinIO replication)
✅ Patroni com 3 nós etcd (incluindo witness em rede isolada)
✅ ArgoCD GitOps em ambos os clusters
✅ Cloudflare Tunnel como camada de borda
✅ Stack de observabilidade completa (Prometheus, Grafana, Loki, Tempo)
✅ Identidade federada via Keycloak (Gov.br homologação)
✅ Fluxo de upload com ClamAV
✅ Testes de chaos engineering (kill pod, partição de rede, latência artificial)

### 2.2 Fora do escopo

❌ Hardware redundante (RAID 1, fonte redundante, link L2L redundante) — propriedade da EVEO
❌ Falha física simultânea de DC inteiro com fidelidade (sem geração elétrica, refrigeração, etc.)
❌ Cloudflare WAF/CDN em volume real (lab usa Free tier com volume limitado)
❌ Gov.br produção (lab usa apenas Gov.br homologação)
❌ Políticas reais do Palo Alto institucional
❌ Tráfego real de produção (sempre dados sintéticos)

## 3. Topologia do Laboratório

### 3.1 Diagrama lógico

```
                        Internet
                            │
                            ▼
          ┌─────────────────────────────────────┐
          │       Cloudflare Edge               │
          │  - DNS authoritative                │
          │    (uniplus-lab.shop)               │
          │  - WAF + Anti-DDoS                  │
          │  - TLS automático                   │
          │  - Edge cache                       │
          └─────────────┬───────────────────────┘
                        │
                        │ Cloudflare Tunnel
                        │ (saída via cloudflared)
                        │
                        ▼
                ROTEADOR TIM FIBRA
                (rede LAN local)
                        │
        ┌───────────────┴────────────────┐
        │                                │
        ▼                                ▼
┌──────────────────┐            ┌────────────────────┐
│  Ryzen 9950X     │            │  Core i7 12ª gen   │
│  Arch Linux      │            │  Ubuntu Server     │
│  64 GB / 2 TB    │            │  32 GB / 1 TB      │
│  IP: 192.168.x.10│            │  IP: 192.168.x.20  │
│                  │            │                    │
│  "EVEO SP1"      │            │  "EVEO SP2"        │
│  ─────────────   │            │  ─────────────     │
│  K3s cluster A   │  ◄── L2L ──►   K3s cluster B   │
│  Postgres P/R    │   (LAN GbE  │  Postgres R/P     │
│  Kafka brokers   │  + tc netem)│  Kafka broker     │
│  MinIO node      │            │  MinIO node       │
│  cloudflared     │            │  cloudflared      │
│                  │            │                   │
│                  │            │  ┌──────────────┐ │
│                  │            │  │ Container    │ │
│                  │            │  │ "UNIFESSPA   │ │
│                  │            │  │  Witness"    │ │
│                  │            │  │ (rede sep.)  │ │
│                  │            │  │              │ │
│                  │            │  │ etcd witness │ │
│                  │            │  │ Keycloak Mst │ │
│                  │            │  │ MinIO Master │ │
│                  │            │  └──────────────┘ │
└──────────────────┘            └────────────────────┘
```

### 3.2 Mapeamento de hardware

| Papel em produção | Máquina no lab | Especificação |
|-------------------|----------------|---------------|
| EVEO SP1 (Cotia) — servidor primário | **Ryzen 9 9950X** | 16C/32T, 64 GB DDR5, 2 TB NVMe, rede 2.5 Gbps |
| EVEO SP2 (Osasco) — servidor secundário | **Core i7 12ª gen** | 12C/16-20T, 32 GB DDR4, 1 TB NVMe, rede 1 Gbps |
| UNIFESSPA Marabá — witness + serviços internos | **Container isolado** na máquina i7 | 1 vCPU, 2 GB RAM, rede separada |

### 3.3 Domínios

A simulação usa o domínio `uniplus-lab.shop` (registrado em registrar comercial, gerenciado via Cloudflare):

| Domínio | Endpoint |
|---------|----------|
| `uniplus-lab.shop` | Frontend principal (default → /portal) |
| `uniplus-lab.shop/portal` | Frontend Portal |
| `uniplus-lab.shop/selecao` | Frontend Seleção |
| `uniplus-lab.shop/ingresso` | Frontend Ingresso |
| `api.uniplus-lab.shop/portal` | API Portal |
| `api.uniplus-lab.shop/selecao` | API Seleção |
| `api.uniplus-lab.shop/ingresso` | API Ingresso |
| `auth.uniplus-lab.shop` | Keycloak Réplica |
| `s3.uniplus-lab.shop` | MinIO |
| `argocd.uniplus-lab.shop` | ArgoCD UI |
| `grafana.uniplus-lab.shop` | Grafana |
| `vault.uniplus-lab.shop` | Vault UI |

### 3.4 Distribuição de recursos no lab

#### Ryzen 9950X — "EVEO SP1"

| Camada | RAM | Threads |
|--------|-----|---------|
| Sistema operacional + buffer | 8 GB | 4 |
| Cluster K3s A (control plane + worker) | 16 GB | 8 |
| 3× PostgreSQL no host | 8 GB | 4 |
| Kafka broker (1-2 brokers) | 6 GB | 4 |
| MinIO node | 4 GB | 2 |
| **Total** | **42 GB** | **22** |

#### Core i7 12ª gen — "EVEO SP2"

| Camada | RAM | Threads |
|--------|-----|---------|
| Sistema operacional + buffer | 6 GB | 2 |
| Cluster K3s B (control plane + worker) | 10 GB | 6 |
| 3× PostgreSQL no host | 6 GB | 3 |
| Kafka broker | 4 GB | 3 |
| MinIO node | 3 GB | 2 |
| Container "UNIFESSPA witness" | 2.5 GB | 2 |
| **Total** | **31.5 GB** | **18** |

### 3.5 Latência simulada

A LAN doméstica entre as duas máquinas tem latência típica de 0.3-0.8 ms. Para simular o L2L EVEO realisticamente (que mede <1 ms), nenhuma intervenção é necessária. Para **simular cenários piores** (link com latência ou perda), usamos `tc netem` no Linux:

```bash
# Adiciona 5 ms de latência simulando link mais lento
sudo tc qdisc add dev eth0 root netem delay 5ms

# Simula instabilidade (latência variável + perda de pacotes)
sudo tc qdisc add dev eth0 root netem delay 5ms 2ms loss 0.1%

# Remove a interferência
sudo tc qdisc del dev eth0 root
```

## 4. Mapeamento Lab ↔ Produção

| Aspecto | Produção (EVEO) | Laboratório |
|---------|-----------------|-------------|
| **Hardware DC** | Servidor dedicado Tier III | Workstation pessoal Linux |
| **CPU** | Xeon Gold 6138 (40C/80T por DC) | Ryzen 9950X (32T) + i7 12ª (16T) |
| **RAM** | 96 GB DDR4 ECC por DC | 64 GB DDR5 + 32 GB DDR4 |
| **Storage** | 2 TB NVMe RAID 1 por DC | 2 TB NVMe + 1 TB NVMe (sem RAID) |
| **Link inter-DC** | L2L privado 500 Mbps redundante | LAN GbE doméstica |
| **Latência inter-DC** | < 1 ms RTT | 0.3-0.8 ms RTT |
| **Borda externa** | Cloudflare (decisão pendente) | Cloudflare Tunnel (Free tier) |
| **DNS** | unifesspa.edu.br (delegação a definir) | uniplus-lab.shop (Cloudflare) |
| **TLS** | Cloudflare ou cert-manager + Let's Encrypt | Cloudflare automático |
| **K8s** | K3s ou similar 1.30+ | K3s 1.30+ (mesma distribuição) |
| **Postgres** | PostgreSQL 16 + Patroni + PgBouncer | Idem |
| **Kafka** | KRaft mode, 3 brokers | Idem |
| **MinIO** | Distribuído entre DCs | Idem (escala reduzida) |
| **Identidade** | Gov.br produção | Gov.br homologação |
| **UNIFESSPA** | Marabá-PA com Palo Alto + serviços | Container isolado na máquina i7 |
| **Backup destino** | Infra UNIFESSPA real | "UNIFESSPA simulada" no container |

**Princípio:** mesma stack, mesmas tecnologias, mesmas versões. Apenas o substrato físico difere.

## 5. Cenários de Validação

Os cenários abaixo serão executados sequencialmente, do mais simples ao mais complexo. Cada cenário tem **hipótese**, **procedimento**, **métricas** e **critério de sucesso** definidos.

### Cenário 1: Provisionamento e bootstrap

**Objetivo:** validar que o ambiente é reproduzível a partir do zero usando os scripts e manifests do repositório.

**Hipótese:** executando `./scripts/bootstrap-lab.sh` em uma máquina recém-instalada, o cluster K3s, ArgoCD, Vault e demais componentes ficam operacionais em ≤ 60 minutos.

**Procedimento:**
1. Instalar Ubuntu Server 24.04 LTS limpo na máquina i7
2. Clonar `uniplus-infra`
3. Executar `./scripts/bootstrap-lab.sh --role=sp2`
4. Verificar com `./scripts/validate-cluster.sh`

**Métricas:**
- Tempo total de bootstrap
- Número de erros/warnings durante execução
- Componentes operacionais ao final

**Critério de sucesso:** todos os componentes do diagrama operacionais em ≤ 60 min, sem intervenção manual além do esperado.

---

### Cenário 2: Sincronização GitOps multi-cluster

**Objetivo:** validar que o ArgoCD em ambos os clusters reconcilia mudanças do repositório.

**Hipótese:** um commit em `main` é aplicado em ≤ 3 minutos em ambos os clusters de forma idempotente.

**Procedimento:**
1. Ambos os clusters com ArgoCD operacional, apontando para `main`
2. Commit de mudança trivial (ex: alteração em ConfigMap)
3. Push para `origin/main`
4. Cronometrar até reconciliação em SP1 e SP2

**Métricas:**
- Tempo da push até cada cluster aplicar
- Drift detectado em algum cluster
- Logs de sincronização

**Critério de sucesso:** ambos os clusters atingem estado desejado em ≤ 3 minutos, sem necessidade de intervenção.

---

### Cenário 3: Failover automático do PostgreSQL via Patroni

**Objetivo:** medir o tempo real de failover quando o primary é perdido abruptamente.

**Hipótese:** Patroni promove o standby a primary em ≤ 30 segundos, com perda de dados ≤ 1 segundo (lag de replicação típico).

**Procedimento:**
1. Cluster PostgreSQL operacional (1 primary em SP1, 1 standby em SP2, etcd witness em UNIFESSPA simulada)
2. Aplicação ativamente escrevendo na base via PgBouncer (script de carga sintética)
3. **Kill abrupto** do container PostgreSQL primary em SP1 (`docker kill postgres-primary`)
4. Cronometrar até standby em SP2 virar primary
5. Verificar consistência dos dados após failover

**Métricas:**
- Tempo de detecção pelo Patroni
- Tempo de promoção do standby
- Tempo de re-roteamento do PgBouncer
- Última transação confirmada antes da perda
- Primeira transação aceita após failover

**Critério de sucesso:**
- Failover total ≤ 30 segundos
- Perda de dados ≤ 1 segundo (limitada ao lag async)
- Aplicação reconecta automaticamente após reconfiguração do PgBouncer

---

### Cenário 4: Prevenção de split-brain via witness etcd

**Objetivo:** demonstrar empiricamente o valor do witness etcd na UNIFESSPA.

**Hipótese:** com partição de rede entre SP1 e SP2 (mas ambos enxergando o witness), o lado conectado ao witness mantém o primary; o outro lado vira read-only.

**Procedimento:**

**Parte A — sem witness (cenário negativo):**
1. Reconfigurar Patroni com apenas 2 nós etcd (SP1 e SP2, sem witness)
2. Provocar partição de rede com firewall: bloquear tráfego SP1↔SP2
3. Observar comportamento (ambos os lados podem virar primary → split-brain)
4. Documentar a divergência de dados resultante

**Parte B — com witness (cenário pretendido):**
1. Reconfigurar com 3 nós etcd: SP1 + SP2 + witness UNIFESSPA
2. Provocar mesma partição entre SP1↔SP2 (mas mantendo SP1↔witness e SP2↔witness)
3. Observar comportamento
4. Verificar qual lado se manteve como primary

**Métricas:**
- Tempo até detecção da partição
- Identificação correta do lado isolado
- Lado isolado vira read-only?
- Lado conectado ao witness mantém primary?

**Critério de sucesso:**
- Parte A: split-brain ocorre (resultado esperado, prova o problema)
- Parte B: split-brain é prevenido em ≤ 60 segundos, lado isolado vira read-only

**Importância:** este cenário é particularmente valioso para a Divisão de Redes — prova com dados a necessidade do nó witness na UNIFESSPA.

---

### Cenário 5: Catch-up após manutenção planejada

**Objetivo:** validar tempo de recuperação após "DC inteiro" ficar fora por período prolongado.

**Hipótese:** SP2 fora por 1 hora consegue se sincronizar completamente em ≤ 30 minutos após retorno.

**Procedimento:**
1. Ambiente operacional, com aplicação gerando carga de escrita constante em SP1 (primary)
2. Desligar máquina i7 (simula "manutenção do DC SP2")
3. Manter operação em SP1 por 60 minutos com carga ativa
4. Religar máquina i7
5. Observar Patroni reincorporar SP2 como standby
6. Medir tempo até replicação atingir lag = 0

**Métricas:**
- Volume de WAL acumulado durante "indisponibilidade"
- Tempo até standby recuperar consistência
- Banda usada na recuperação

**Critério de sucesso:** standby em SP2 atinge `replay_lag = 0` em ≤ 30 minutos.

---

### Cenário 6: Replicação Kafka entre brokers

**Objetivo:** validar continuidade de eventos em caso de falha de broker.

**Hipótese:** com `replication.factor=2` e `min.insync.replicas=1`, o cluster sobrevive à falha de um broker sem perda de mensagens.

**Procedimento:**
1. Cluster Kafka operacional (3 brokers distribuídos: 2 em SP1, 1 em SP2)
2. Producer enviando mensagens continuamente para tópico de teste
3. Consumer agregando recebimentos
4. Kill abrupto do broker líder de uma partição
5. Verificar que producer e consumer continuam operando
6. Verificar que nenhuma mensagem é perdida

**Métricas:**
- Mensagens enviadas vs recebidas (0 perdas)
- Tempo de re-eleição de líder
- Latência durante a transição

**Critério de sucesso:** zero mensagens perdidas, re-eleição em ≤ 10 segundos.

---

### Cenário 7: MinIO erasure coding distribuído

**Objetivo:** validar que objetos permanecem acessíveis após perda de um nó.

**Hipótese:** com 4 nós lógicos (2 por DC) em modo distribuído, a perda de 1 nó mantém leitura/escrita disponível.

**Procedimento:**
1. MinIO distribuído operacional
2. Upload de 100 objetos de tamanhos variados (1 KB a 100 MB)
3. Kill de 1 nó MinIO
4. Tentar leitura dos 100 objetos
5. Tentar escrita de 50 novos objetos
6. Religar o nó e verificar healing automático

**Métricas:**
- Objetos lidos com sucesso após falha (esperado: 100/100)
- Objetos escritos com sucesso (esperado: 50/50)
- Tempo de healing após retorno do nó

**Critério de sucesso:** 100% de disponibilidade durante a falha, healing completo em ≤ 15 minutos após retorno.

---

### Cenário 8: Carga em pico de edital

**Objetivo:** medir comportamento sob carga representativa do uso real esperado.

**Hipótese:** o sistema atende 2.000 usuários simultâneos com latência p95 ≤ 2 segundos.

**Procedimento:**
1. Ambiente em estado estável
2. Gerar carga via `k6` ou `Locust`:
   - 500 usuários simultâneos por 5 minutos (warm-up)
   - 1.000 usuários simultâneos por 10 minutos
   - 2.000 usuários simultâneos por 10 minutos (pico)
3. Workload representativo: 60% leitura (consulta editais), 30% escrita (inscrições), 10% upload (documentos)
4. Coletar métricas via Prometheus + Grafana

**Métricas:**
- Latência p50, p95, p99 por endpoint
- Throughput (req/s)
- Taxa de erro (4xx, 5xx)
- Uso de CPU/RAM/disco/rede em cada componente
- Lag de replicação Postgres durante pico

**Critério de sucesso:**
- Latência p95 ≤ 2s
- Taxa de erro ≤ 0.1%
- Sistema estável (sem OOM, sem CrashLoopBackOff)
- Lag de replicação ≤ 5s sustentado

**Limitação importante:** sua máquina é menos potente que produção EVEO. Os números servem para validar **comportamento qualitativo** (sistema sobrevive ao pico) e não como número absoluto de produção.

---

### Cenário 9: Fluxo end-to-end de upload com ClamAV

**Objetivo:** exercitar o fluxo completo de upload com análise antimalware assíncrona.

**Hipótese:** uploads passam por análise e são reclassificados em ≤ 60 segundos para arquivos típicos (≤ 10 MB).

**Procedimento:**
1. Login via Gov.br homologação
2. Upload de 3 arquivos:
   - **A**: PDF legítimo de 5 MB
   - **B**: imagem PNG de 2 MB
   - **C**: arquivo EICAR (assinatura padrão antivírus)
3. Acompanhar via dashboard:
   - Recebimento da presigned URL
   - Upload direto ao MinIO (bucket `quarentena/`)
   - Evento Kafka publicado
   - ClamAV consome e processa
   - Movimentação para `aprovado/` (A, B) ou `bloqueado/` (C)
   - Notificação ao usuário via WebSocket

**Métricas:**
- Tempo de cada etapa
- Bucket final de cada arquivo
- Mensagens Kafka publicadas
- Eventos de auditoria registrados

**Critério de sucesso:**
- A e B aprovados, em `aprovado/` em ≤ 60s
- C rejeitado, em `bloqueado/`, com incidente registrado em log

---

### Cenário 10: Autenticação Gov.br homologação

**Objetivo:** validar fluxo completo de federação Gov.br via Keycloak.

**Hipótese:** o fluxo OIDC com Identity Brokering funciona end-to-end com Gov.br homologação.

**Procedimento:**
1. Acessar `uniplus-lab.shop/selecao`
2. Iniciar login → redireciona para Keycloak Réplica
3. Selecionar "Entrar com Gov.br"
4. Keycloak Réplica → Keycloak Master → Gov.br homologação
5. Autenticar com CPF de teste do Gov.br
6. Retornar ao frontend autenticado
7. Fazer requisição autenticada à API
8. Validar token JWT no servidor

**Métricas:**
- Tempo total do fluxo de login
- Atributos retornados pelo Gov.br
- Mapeamento de roles aplicado
- Validade e estrutura do JWT emitido

**Critério de sucesso:** fluxo completo funcional, JWT válido, claims corretas, acesso autorizado às APIs.

---

### Cenário 11: Cloudflare Tunnel + WAF

**Objetivo:** validar a opção da camada de borda Cloudflare apresentada no DT-UNIPLUS-001 Seção 9.1.

**Hipótese:** o Cloudflare Tunnel fornece exposição segura com WAF ativo, sem necessidade de IP público.

**Procedimento:**
1. Configurar Cloudflare Tunnel em ambas as máquinas (Ryzen e i7)
2. DNS `uniplus-lab.shop` apontando para o tunnel
3. Acessar de várias redes externas (móvel 4G, outra rede)
4. Disparar requisições com payloads OWASP típicos:
   - SQL injection em parâmetros
   - XSS em campos de formulário
   - Path traversal
5. Verificar bloqueio pelo WAF Cloudflare
6. Desligar Ryzen → verificar se Cloudflare redireciona para i7 (failover automático)

**Métricas:**
- Tempo de propagação DNS
- TLS válido (cert Cloudflare)
- Payloads OWASP bloqueados pelo WAF
- Failover entre `cloudflared` em segundos

**Critério de sucesso:**
- Acesso via internet pública sem IP público no lab
- WAF bloqueia ataques OWASP padrão
- Failover automático entre Ryzen e i7 em ≤ 30s

**Importância:** gera dados objetivos para a Divisão de Redes decidir sobre Cloudflare em produção.

---

### Cenário 12: Backup e restore para "UNIFESSPA simulada"

**Objetivo:** validar fluxo de backup e procedimento de DR.

**Hipótese:** restore completo a partir de backup é possível em ≤ 1 hora.

**Procedimento:**
1. Configurar pgBackRest com destino na "UNIFESSPA simulada" (container)
2. Operação normal por 48 horas (backups full + diferenciais + WAL contínuo)
3. **Cenário catastrófico:** wipe completo de SP1 e SP2 (drop bancos, deletar volumes)
4. Restaurar a partir do backup na UNIFESSPA simulada
5. Validar consistência dos dados restaurados
6. Medir RPO real (última transação preservada)

**Métricas:**
- Volume total de backups acumulados
- Tempo de restore
- Última transação preservada vs perdida
- Integridade dos dados restaurados

**Critério de sucesso:**
- Restore completo em ≤ 1 hora (RTO)
- Perda de dados ≤ 5 minutos (RPO)
- 100% de integridade nos dados restaurados

## 6. Métricas e Critérios de Sucesso

### 6.1 Métricas globais

Para cada cenário, coletar:

- **Latência**: p50, p95, p99 das operações principais
- **Throughput**: requisições/segundo, eventos/segundo, MB/s
- **Disponibilidade**: % de tempo com sistema responsivo durante o teste
- **Recursos**: CPU, RAM, disco, rede em cada nó
- **Erros**: 4xx/5xx HTTP, exceptions nas aplicações, eventos Kafka mortos

### 6.2 Ferramentas de coleta

- **Prometheus**: métricas técnicas (todas as anteriores)
- **Grafana**: dashboards consolidados, comparações antes/durante/depois
- **Loki**: logs estruturados de todas as aplicações
- **Tempo**: traces distribuídos para análise de causa raiz
- **k6 / Locust**: geração de carga sintética
- **chaos-mesh** (opcional): orquestração de cenários de falha

### 6.3 Critérios de "Pronto para Produção"

A arquitetura é considerada validada quando:

| Critério | Status mínimo |
|----------|---------------|
| Cenários 1-12 executados | Todos |
| Cenários com critério de sucesso atingido | ≥ 10/12 |
| RPO real medido | ≤ 5 minutos |
| RTO real medido | ≤ 1 hora |
| Failover Postgres | ≤ 30 segundos |
| Split-brain prevention | Demonstrado |
| Capacidade suportada | ≥ 1.000 usuários simultâneos no lab |

## 7. Limitações Declaradas

Limitações conhecidas do laboratório que devem ser consideradas ao interpretar os resultados:

| Limitação | Impacto |
|-----------|---------|
| Hardware doméstico vs servidor enterprise | Números absolutos de performance não comparáveis a produção |
| LAN gigabit vs L2L 500 Mbps | Banda inter-DC superior no lab; resultados de catch-up otimistas |
| Sem RAID 1, sem fonte redundante | Não testa cenários de falha de hardware no nó |
| Cloudflare Free tier | Volume de testes WAF limitado, sem bot management avançado |
| Gov.br homologação | Fluxo idêntico ao produção, mas usuários sintéticos |
| Sem Palo Alto real | Não testa políticas reais; usa iptables/ufw como substituto |
| 1 cluster K3s single-node por DC | Em produção, esperam-se múltiplos workers; capacity planning não 1:1 |
| Sem teste de tráfego real >2.000 simultâneos | Limitação da capacidade do gerador de carga local |

## 8. Cronograma

Estimativa baseada em equipe de 1 tech lead + 1 analista de sistemas dedicados parcialmente.

| Semana | Atividade |
|--------|-----------|
| 1 | Setup das máquinas (Cenário 1) — bootstrap completo |
| 2 | Cenários 2 e 3 — GitOps e failover Postgres |
| 3 | Cenário 4 — split-brain prevention (mais valioso para Divisão de Redes) |
| 4 | Cenários 5, 6, 7 — catch-up, Kafka, MinIO |
| 5 | Cenário 8 — carga em pico (mais demorado, com tunnings) |
| 6 | Cenários 9 e 10 — fluxos end-to-end (upload, Gov.br) |
| 7 | Cenário 11 — Cloudflare Tunnel e WAF |
| 8 | Cenário 12 — backup e restore |
| 9 | Consolidação de relatório final |
| 10 | Apresentação dos resultados à Divisão de Redes |

**Estimativa total: 10 semanas (≈ 2,5 meses)** para validação completa.

## 9. Uso dos Resultados

Os resultados deste plano de validação serão usados para:

### 9.1 Subsidiar a Divisão de Redes

Os cenários 4 (split-brain), 11 (Cloudflare) e 12 (backup) geram dados objetivos para os pontos abertos do **DT-UNIPLUS-001**:

- **Seção 9.1 (proteção de borda)** ← Cenário 11
- **Seção 9.2 (túneis IPSEC)** ← Cenário 4
- **Seção 9.5 (DNS)** ← Cenário 11
- **Seção 9.7 (resposta a incidentes)** ← Cenários 8, 9, 11

### 9.2 Confirmar dimensionamento

Os cenários 5, 6, 7 e 8 validam que os recursos contratados na EVEO (96 GB RAM, 80 threads por DC) são suficientes para os requisitos não-funcionais.

### 9.3 Refinar runbooks operacionais

Os cenários 3, 4, 5 e 12 produzem runbooks detalhados de failover, recuperação e DR, que servirão de referência para a operação em produção.

### 9.4 Demonstração executiva

Os cenários 4, 8 e 11 produzem **demonstrações visuais** (vídeo, capturas de Grafana) que podem ser apresentados à Reitoria e à Diretoria do CTIC como evidência de rigor técnico do projeto.

## 10. Histórico de versões

| Versão | Data | Autor | Mudanças |
|--------|------|-------|----------|
| 1.0 | Abr/2026 | Jeferson Ferreira | Versão inicial |

---

*Este documento é vivo e será atualizado conforme cenários são executados e resultados são incorporados. Eventuais ajustes em hipóteses ou critérios serão registrados no histórico de versões.*

*Mantido pelo CTIC/UNIFESSPA — [github.com/unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra)*
