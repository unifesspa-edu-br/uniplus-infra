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

Validar empiricamente a réplica mínima da arquitetura Uni+ documentada em [ARCHITECTURE.md](ARCHITECTURE.md), antes da implantação em produção e da exposição da plataforma à comunidade UNIFESSPA. O foco desta validação é de engenharia: redundância, escalabilidade, observabilidade, rastreamento e recuperabilidade.

### 1.2 Objetivos específicos

1. **Provar resiliência 3-DC**: demonstrar que a arquitetura ativo-ativo entre `SP1`, `SP2` e `PA1` permanece disponível com a queda de qualquer 1 DC.
2. **Validar recuperabilidade**: medir backup, restore, backlog e equalização quando `PA1` fica indisponível por algumas horas e retorna.
3. **Validar failover de banco**: medir o tempo real de failover do PostgreSQL via Patroni com consenso distribuído e `pa1-consensus-witness` quando aplicável.
4. **Mensurar comportamento sob carga**: simular 500-2.000 usuários simultâneos em pico de edital e medir latência/throughput.
5. **Validar fluxos críticos**: exercitar end-to-end os fluxos de upload com ClamAV e autenticação Gov.br federada.
6. **Gerar evidência operacional**: produzir métricas, logs e traces que comprovem redundância, escalabilidade, observabilidade e recuperação da aplicação.

## 2. Escopo

### 2.1 Dentro do escopo

✅ Topologia ativo-ativo com 3 DCs lógicos: `SP1`, `SP2` e `PA1`
✅ `PA1` como DC institucional, com `pa1-oidc-source`, `pa1-backup`, storage institucional e função de consenso quando aplicável
✅ Replicação/sincronização por mecanismos nativos de cada produto, sem multi-master artificial
✅ Patroni com consenso distribuído quando necessário
✅ ArgoCD GitOps em ambos os clusters
✅ Entrada HTTP/TLS de laboratório apenas para roteamento funcional
✅ Stack de observabilidade completa (Prometheus, Grafana, Loki, Tempo)
✅ Identidade federada via OIDC (implementação atual Keycloak) e gov.br homologação
✅ Fluxo de upload com ClamAV
✅ Testes de chaos engineering (kill pod, partição de rede, latência artificial)

### 2.2 Fora do escopo

❌ Hardware redundante (RAID 1, fonte redundante, link L2L redundante) — propriedade da EVEO
❌ Falha física simultânea de DC inteiro com fidelidade (sem geração elétrica, refrigeração, etc.)
❌ Decisões de borda/WAF/CDN, IPSEC, DNS, firewall e inspeção TLS — responsabilidade de infraestrutura/rede
❌ Gov.br produção (lab usa apenas Gov.br homologação)
❌ Políticas reais do Palo Alto institucional
❌ Tráfego real de produção (sempre dados sintéticos)

## 3. Topologia do Laboratório

### 3.1 Diagrama lógico

```
                 Internet / domínio de lab
                           │
                           ▼
              ┌─────────────────────────┐
              │ Entrada HTTP/TLS de lab │
              │ DNS/tunnel provisório   │
              └───────────┬─────────────┘
                          │
                 rede LAN local
                          │
      ┌───────────────────┼───────────────────┐
      ▼                   ▼                   ▼
┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ SP1          │    │ SP2          │    │ PA1          │
│ EVEO Cotia   │    │ EVEO Osasco  │    │ UNIFESSPA    │
│ simulado     │    │ simulado     │    │ simulado     │
│              │    │              │    │              │
│ K3s/apps     │    │ K3s/apps     │    │ pa1-backup   │
│ OIDC local   │    │ OIDC local   │    │ pa1-oidc-src │
│ Postgres     │◄──►│ Postgres     │◄──►│ LDAP sint.   │
│ Kafka/MinIO  │◄──►│ Kafka/MinIO  │◄──►│ storage/DR   │
│ observab.    │    │ observab.    │    │ consensus    │
└──────────────┘    └──────────────┘    └──────────────┘
```

### 3.2 Mapeamento de hardware

| Papel em produção | Máquina no lab | Especificação |
|-------------------|----------------|---------------|
| EVEO SP1 (Cotia) — servidor primário | **Ryzen 9 9950X** | 16C/32T, 64 GB DDR5, 2 TB NVMe, rede 2.5 Gbps |
| EVEO SP2 (Osasco) — servidor secundário | **Core i7 12ª gen** | 12C/16-20T, 32 GB DDR4, 1 TB NVMe, rede 1 Gbps |
| UNIFESSPA Marabá — `PA1` institucional | **Container isolado** na máquina i7 | Recursos dedicados para `pa1-backup`, `pa1-oidc-source`, LDAP sintético, storage/DR e consenso |

### 3.3 Domínios

A simulação pode usar o domínio `uniplus-lab.shop` com DNS/tunnel provisório apenas para expor a PoC. Essa escolha não valida a solução institucional de borda:

| Domínio | Endpoint |
|---------|----------|
| `uniplus-lab.shop` | Frontend principal (default → /portal) |
| `uniplus-lab.shop/portal` | Frontend Portal |
| `uniplus-lab.shop/selecao` | Frontend Seleção |
| `uniplus-lab.shop/ingresso` | Frontend Ingresso |
| `api.uniplus-lab.shop/portal` | API Portal |
| `api.uniplus-lab.shop/selecao` | API Seleção |
| `api.uniplus-lab.shop/ingresso` | API Ingresso |
| `auth.uniplus-lab.shop` | OIDC lógico do Uni+ |
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
| Container `PA1` institucional | 2.5 GB+ | 2+ |
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
| **Borda externa** | A definir por infraestrutura/rede | Entrada HTTP/TLS provisória de lab |
| **DNS** | unifesspa.edu.br (delegação a definir) | uniplus-lab.shop ou `/etc/hosts` |
| **TLS** | A definir por infraestrutura/rede | Certificado provisório ou TLS automático do lab |
| **K8s** | K3s ou similar 1.30+ | K3s 1.30+ (mesma distribuição) |
| **Postgres** | PostgreSQL 16 + Patroni + PgBouncer | Idem |
| **Kafka** | KRaft mode, 3 brokers | Idem |
| **MinIO** | Distribuído entre DCs | Idem (escala reduzida) |
| **Identidade** | Gov.br produção | Gov.br homologação |
| **PA1 / UNIFESSPA** | Marabá-PA com Palo Alto, LDAP, OIDC institucional, backup e DR | Container isolado na máquina i7 |
| **Backup destino** | `pa1-backup` no DC institucional | `pa1-backup` no container PA1 |

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
1. Cluster PostgreSQL operacional (primaries distribuídos entre `SP1` e `SP2`, réplicas nos demais nós e consenso com `pa1-consensus-witness` quando aplicável)
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

### Cenário 4: Queda do PA1 sem interromper atendimento

**Objetivo:** demonstrar que `PA1` não é ponto único de falha do sistema.

**Hipótese:** com `PA1` fora por algumas horas, `SP1` e `SP2` continuam atendendo tráfego de usuário, login principal via gov.br/OIDC, escrita operacional e leitura. Backups, sincronização institucional e retenção entram em modo degradado até o retorno do `PA1`.

**Procedimento:**
1. Ambiente 3-DC operacional, com `SP1`, `SP2` e `PA1` sincronizados
2. Gerar carga sintética em `SP1`/`SP2`
3. Derrubar o container ou host lógico `PA1`
4. Executar login via gov.br/OIDC e chamadas às APIs
5. Confirmar que backups/replicações para `PA1` entram em backlog local
6. Reativar `PA1`
7. Medir tempo até sincronização e backlog voltarem a zero

**Métricas:**
- Disponibilidade HTTP em `SP1`/`SP2`
- Sucesso de login via OIDC
- Tamanho do backlog de backup/replicação
- Tempo de equalização após retorno de `PA1`
- Erros e traces durante a janela de degradação

**Critério de sucesso:**
- Sistema permanece disponível em `SP1`/`SP2`
- Login principal via gov.br/OIDC continua funcionando
- Backlog local é preservado sem perda de dados
- Retorno de `PA1` sincroniza backlog até zero sem intervenção manual destrutiva

**Importância:** este cenário prova que `PA1` é DC institucional de soberania, backup e sincronização, mas não ponto único de falha do atendimento normal.

---

### Cenário 5: Queda de SP1 ou SP2 com atendimento pelo DC restante

**Objetivo:** validar que a perda de qualquer DC externo não derruba a aplicação.

**Hipótese:** `SP1` e `SP2` são ativos para tráfego de usuário; se um deles cair, o outro continua atendendo. Quando o DC retornar, bancos, Kafka, MinIO, GitOps e observabilidade devem convergir.

**Procedimento:**
1. Ambiente operacional, com tráfego distribuído entre `SP1` e `SP2`
2. Derrubar `SP1`
3. Validar atendimento por `SP2`
4. Retornar `SP1` e medir equalização
5. Repetir o mesmo procedimento derrubando `SP2`

**Métricas:**
- Volume de WAL acumulado durante "indisponibilidade"
- Tempo até tráfego estabilizar no DC restante
- Tempo até réplicas recuperarem consistência
- Banda usada na recuperação
- Erros HTTP e traces durante failover

**Critério de sucesso:** queda de `SP1` ou `SP2` não torna o sistema indisponível; o DC recuperado equaliza dados e estado operacional sem perda além do RPO validado.

---

### Cenário 6: Replicação Kafka entre brokers

**Objetivo:** validar continuidade de eventos em caso de falha de broker.

**Hipótese:** com quorum/replicação nativos e distribuição adequada de brokers/controllers, o cluster sobrevive à falha de um broker e, no cenário alvo, à perda temporária de 1 DC.

**Procedimento:**
1. Cluster Kafka operacional distribuído entre `SP1`, `SP2` e `PA1`, quando a latência permitir
2. Producer enviando mensagens continuamente para tópico de teste
3. Consumer agregando recebimentos
4. Kill abrupto do broker líder de uma partição
5. Verificar que producer e consumer continuam operando
6. Verificar que nenhuma mensagem é perdida

**Métricas:**
- Mensagens enviadas vs recebidas (0 perdas)
- Tempo de re-eleição de líder
- Latência durante a transição

**Critério de sucesso:** zero mensagens perdidas no cenário de broker individual; para queda de DC, o comportamento aceito deve estar explicitamente validado conforme quorum escolhido.

---

### Cenário 7: Object storage com replicação nativa

**Objetivo:** validar que objetos permanecem acessíveis após perda de um DC ou nó conforme a política de replicação escolhida.

**Hipótese:** com replicação/site ou bucket replication nativa entre `SP1`, `SP2` e `PA1`, objetos continuam disponíveis durante perda de 1 DC conforme política definida para leitura/escrita.

**Procedimento:**
1. MinIO/object storage operacional em `SP1`, `SP2` e `PA1`
2. Upload de 100 objetos de tamanhos variados (1 KB a 100 MB)
3. Derrubar 1 nó/site MinIO conforme desenho da PoC
4. Tentar leitura dos 100 objetos
5. Tentar escrita de 50 novos objetos
6. Religar o nó e verificar healing automático

**Métricas:**
- Objetos lidos com sucesso após falha (esperado: 100/100)
- Objetos escritos com sucesso (esperado: 50/50)
- Tempo de healing após retorno do nó

**Critério de sucesso:** objetos permanecem acessíveis conforme política definida, e o DC recuperado equaliza replicação/healing após retorno.

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

### Cenário 10: Autenticação Gov.br/OIDC com PA1 indisponível

**Objetivo:** validar fluxo completo de federação Gov.br via OIDC e confirmar que `PA1` não é dependência síncrona do login normal.

**Hipótese:** o fluxo OIDC com Identity Brokering funciona end-to-end com Gov.br homologação em `SP1` e `SP2`, mesmo com LDAP/`pa1-oidc-source` indisponível temporariamente.

**Procedimento:**
1. Acessar `uniplus-lab.shop/selecao`
2. Iniciar login → redireciona para o endpoint OIDC lógico do Uni+
3. Selecionar "Entrar com Gov.br"
4. Serviço OIDC do DC ativo → Gov.br homologação
5. Autenticar com CPF de teste do Gov.br
6. Retornar ao frontend autenticado
7. Fazer requisição autenticada à API
8. Validar token JWT no servidor
9. Derrubar `PA1` e repetir o fluxo em `SP1`/`SP2`

**Métricas:**
- Tempo total do fluxo de login
- Atributos retornados pelo Gov.br
- Mapeamento de roles aplicado
- Validade e estrutura do JWT emitido

**Critério de sucesso:** fluxo completo funcional, JWT válido, claims corretas, acesso autorizado às APIs e nenhuma dependência síncrona obrigatória de LDAP/`PA1` para o login principal.

---

### Cenário 11: Observabilidade, logs e traces durante falhas

**Objetivo:** demonstrar que a plataforma permite diagnosticar falhas e recuperação com métricas, logs e traces correlacionados.

**Hipótese:** durante queda de pod, falha de DC, backlog de backup e retorno de `PA1`, Prometheus, Loki e Tempo mostram sinais suficientes para identificar causa, impacto, duração e recuperação.

**Procedimento:**
1. Executar carga sintética com `X-Correlation-Id`
2. Derrubar um pod de API e observar recriação pelo K8s
3. Simular queda de `SP1`, `SP2` e `PA1` em janelas separadas
4. Acompanhar métricas de disponibilidade, latência, erro, backlog e uso de recursos
5. Consultar logs por correlation id
6. Abrir trace end-to-end no Tempo/OTel e identificar a etapa degradada

**Métricas:**
- Latência p50/p95/p99
- Taxa de erro por serviço/DC
- Backlog de backup/replicação
- Tempo até recuperação
- Percentual de requests com trace completo
- Logs encontrados por correlation id

**Critério de sucesso:**
- Dashboards indicam claramente indisponibilidade, degradação e recuperação
- Logs não expõem PII sensível
- Traces permitem rastrear pelo menos um fluxo HTTP → API → banco/mensageria
- Queda de `PA1` aparece como degradação de backup/sincronização, não como indisponibilidade total

---

### Cenário 12: Backup, backlog e restore via PA1

**Objetivo:** validar fluxo de backup e procedimento de DR.

**Hipótese:** restore completo a partir de backup é possível em ≤ 1 hora.

**Procedimento:**
1. Configurar pgBackRest com destino no `pa1-backup`
2. Operação normal por 48 horas (backups full + diferenciais + WAL contínuo)
3. Derrubar `PA1` por algumas horas e manter escrita ativa em `SP1`/`SP2`
4. Confirmar spool/backlog local de WAL/backups
5. Retornar `PA1` e aguardar equalização do backlog
6. **Cenário catastrófico:** wipe completo de SP1 e SP2 (drop bancos, deletar volumes)
7. Restaurar a partir do backup em `PA1`
8. Validar consistência dos dados restaurados
9. Medir RPO real (última transação preservada)

**Métricas:**
- Volume total de backups acumulados
- Backlog local durante indisponibilidade de `PA1`
- Tempo de equalização após retorno de `PA1`
- Tempo de restore
- Última transação preservada vs perdida
- Integridade dos dados restaurados

**Critério de sucesso:**
- Restore completo em ≤ 1 hora (RTO)
- Perda de dados ≤ 5 minutos (RPO)
- 100% de integridade nos dados restaurados
- Backlog criado durante queda de `PA1` é sincronizado sem intervenção manual destrutiva

---

### Cenário 13: Validação integrada do ambiente Standalone OCI

**Objetivo:** validar que o ambiente standalone monolocal (Epic [#40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40), [ADR-008](adrs/ADR-008-topologia-standalone-monolocal.md)) está saudável end-to-end como provider-agnostic sanity check da plataforma Uni+ — sem cobertura de DR geográfico (que é responsabilidade do desenho `SP1`+`SP2`+`PA1` validado nos Cenários 4-5).

**Hipótese:** após bootstrap completo (RUNBOOKS §8) + Vault populado + ApplicationSet ArgoCD reconciliando, o ciclo `usuário → DNS/TLS → portal Angular → Keycloak → API → Postgres/Kafka/MinIO/Apicurio` funciona end-to-end na primeira tentativa, sem ajustes manuais além dos documentados.

**Não-objetivos** (declarado explicitamente para não confundir com cenários 4-5/12):

- Resiliência a queda de DC — standalone é monolocal por definição.
- Replicação Kafka inter-broker / Postgres failover Patroni — único broker, único primary.
- Validação de RPO/RTO contra desastre regional.
- Backup off-site para `PA1` — Cenário 12.

**Procedimento — matriz de 16 itens:**

| # | Item | Como validar | Status mínimo | Bloqueador |
|---|---|---|---|---|
| 1 | DNS público | `dig +short standalone.portaluni.com.br` retorna IP do Reserved Public IP OCI (Keycloak fica em subpath `/auth/*` no FQDN raiz, sem subdomain dedicado); CNAMEs `portal/selecao/ingresso/api-portal/api-selecao/api-ingresso/minio/kafka-ui/schema-registry/redis-ui` apontam para o mesmo IP. | Todos os 11 hosts resolvem (1 A record + 10 CNAMEs) | #56 (Reserved IP + DNS A) |
| 2 | TLS público | `curl -sI https://standalone.portaluni.com.br/auth/realms/uniplus` responde 200 com `letsencrypt-prod` (não staging) no cert chain. | Cert válido cadeia LE prod | #65 capítulo + cert-manager + DNS-01 challenge |
| 3 | K3s single-node | `kubectl get nodes` mostra `k8s-host` Ready; `kubectl get pods -A` sem CrashLoopBackOff. | 100% Ready | RUNBOOKS §8.1 |
| 4 | ArgoCD reconciliação | `argocd app list` mostra todas as apps `Synced/Healthy`; ApplicationSet detectou cluster pelo label `environment=standalone`. | Todas Synced/Healthy | #62 + RUNBOOKS §8.3 |
| 5 | Vault unsealed + ESO ready | `kubectl -n vault exec ... -- vault status` mostra `Sealed=false`; `kubectl get clustersecretstore vault-default` em `Ready=True`. | Unsealed + ESO Ready | RUNBOOKS §8.4 |
| 6 | Postgres data-host | `ssh ubuntu@10.0.2.87 "sudo systemctl is-active uniplus-postgres"` retorna `active`; `psql -h 10.0.2.87 -U uniplus_admin -c '\l'` lista DBs `keycloak`, `uniplus_portal`, `uniplus_selecao`, `uniplus_ingresso`, `apicurio`. | Service active + 5 DBs | Epic `data/*` (#98 placeholder) |
| 7 | Kafka KRaft + SASL_SSL | `kafka-topics --bootstrap-server 10.0.2.87:9092 --command-config admin.props --list` lista tópicos do Wolverine + `edital_events` (broker SASL_SSL no data-host privado, conforme `environments/standalone/values.yaml` `bootstrapServers: 10.0.2.87:9092` e RUNBOOKS §9 / ADR-009). | Listagem OK + auth OK | Epic `data/*` + ADR-009 |
| 8 | MinIO | `mc alias set standalone https://...; mc ls standalone/` lista buckets `app-uploads`, `vault-backup`. | Buckets visíveis | Epic `data/*` |
| 9 | ClamAV scanner | `kubectl -n uniplus exec deploy/clamav-scanner -- clamdscan --version` retorna versão; pod `Healthy`. | Healthy + responde | chart `apps/clamav-scanner` |
| 10 | Keycloak realm `uniplus` | `curl https://standalone.portaluni.com.br/auth/realms/uniplus/.well-known/openid-configuration \| jq .issuer` retorna `https://standalone.portaluni.com.br/auth/realms/uniplus`; clients `uniplus-portal`, `kafka-ui`, `apicurio-registry`, `uniplus-api-{portal,selecao,ingresso}` presentes. | 8 clients OK | RUNBOOKS §10 + #163 |
| 11 | Apps web (3 SPAs) | `https://portal.standalone.portaluni.com.br/` carrega o Angular bundle (status 200, MIME `text/html`); idem para `selecao` e `ingresso`. | 3 SPAs servindo | #162/PR #171 |
| 12 | APIs (3 backends) | `https://api-{portal,selecao,ingresso}.standalone.portaluni.com.br/health/ready` retorna 200 com `Healthy` agregado. | 3 APIs Healthy | charts `apps/uniplus-api-*` |
| 13 | Apicurio Schema Registry | `curl https://schema-registry.standalone.portaluni.com.br/apis/ccompat/v7/subjects` retorna lista contendo `edital_events-value`. | Subject registrado | #152 + #358 (uniplus-api) |
| 14 | Observabilidade | `https://standalone.portaluni.com.br/grafana/` carrega; dashboards exibem métricas Prometheus de cluster + apps; Loki recebe logs estruturados. | Grafana + Loki + Prometheus OK | Epic observabilidade-local (#103) |
| 15 | Backup placeholder | `ls /var/backups/uniplus-postgres/` no data-host mostra dump diário recente (≤ 24h); MinIO `vault-backup` recebe snapshot do Vault Raft. | Dumps presentes | Epic `data/*` sub-task de backup |
| 16 | Restore placeholder | Execução manual de `pg_restore` em DB sintético recupera dados; `vault operator raft snapshot restore` restaura state. | Procedimento documentado em RUNBOOKS funciona em dry-run | Sub-task RUNBOOKS |

**Itens dependentes da Epic `data/*`** (não bloqueiam Fase 5 estrutural mas marcam validação completa): 6, 7, 8, 15, 16.

**Métricas:**

- Tempo total da matriz (16 itens) — meta: ≤ 30 minutos com cluster já em Synced/Healthy.
- Número de itens em status mínimo na primeira passagem.
- Lista priorizada de gaps com link para issue/PR.

**Critério de sucesso (dois gates):**

- **Gate 1 — Fase 5 estrutural** (responsabilidade do time de plataforma): **11/11 dos itens não-Epic-`data/*`** verdes — 1, 2, 3, 4, 5, 9, 10, 11, 12, 13, 14. Itens 6/7/8/15/16 contam como `pending` aceitável até a Epic `data/*` entregar; **não bloqueiam Fase 5**. Esse gate destrava o ambiente standalone para uso em demo e desenvolvimento integrado.
- **Gate 2 — Validação completa pós-Epic `data/*`** (responsabilidade pós-`data/*`): **16/16** verdes — todos os itens, incluindo 6/7/8/15/16. Esse gate destrava promoção do standalone como ambiente de homologação.
- **Itens obrigatórios em ambos os gates:** Item 10 (Keycloak realm + 8 clients) e Item 13 (Apicurio + subject) — destravam o smoke E2E real (Cenário 13.A abaixo).

**Cenário 13.A — Smoke E2E (login real do portal):**

Pós-matriz, executar o smoke test manual de 6 critérios documentado em [`uniplus-infra#99`](https://github.com/unifesspa-edu-br/uniplus-infra/issues/99):

1. `https://standalone.portaluni.com.br` carrega com cert LE prod.
2. Login com usuário de teste no Keycloak completa e redireciona autenticado.
3. Rota protegida do portal Angular chama `GET /api/portal/me` e renderiza a resposta.
4. Logs sem erros 4xx/5xx no caminho do request.
5. Token JWT contém claim `realm_access.roles` consistente com o realm.
6. Logout limpa sessão e redireciona para tela pública.

Capturar evidência em `docs/validacao/standalone-2026-MM-DD.md` (screenshot + trecho de logs estruturados).

---

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
| Queda de qualquer 1 DC | Sistema principal disponível |
| RPO real medido | ≤ 5 minutos |
| RTO real medido | ≤ 1 hora |
| Failover Postgres | ≤ 30 segundos |
| Retorno/equalização de PA1 | Demonstrado |
| Capacidade suportada | ≥ 1.000 usuários simultâneos no lab |

## 7. Limitações Declaradas

Limitações conhecidas do laboratório que devem ser consideradas ao interpretar os resultados:

| Limitação | Impacto |
|-----------|---------|
| Hardware doméstico vs servidor enterprise | Números absolutos de performance não comparáveis a produção |
| LAN gigabit vs L2L 500 Mbps | Banda inter-DC superior no lab; resultados de catch-up otimistas |
| Sem RAID 1, sem fonte redundante | Não testa cenários de falha de hardware no nó |
| Sem borda/WAF institucional | O laboratório mede a aplicação e a plataforma; políticas de borda ficam fora do escopo da PoC |
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
| 3 | Cenário 4 — queda do PA1 sem interromper atendimento |
| 4 | Cenários 5, 6, 7 — catch-up, Kafka, MinIO |
| 5 | Cenário 8 — carga em pico (mais demorado, com tunings) |
| 6 | Cenários 9 e 10 — fluxos end-to-end (upload, Gov.br) |
| 7 | Cenário 11 — observabilidade, logs e traces durante falhas |
| 8 | Cenário 12 — backup e restore |
| 9 | Consolidação de relatório final |
| 10 | Apresentação dos resultados aos times de Engenharia e CTIC |

**Estimativa total: 10 semanas (≈ 2,5 meses)** para validação completa.

## 9. Uso dos Resultados

Os resultados deste plano de validação serão usados para:

### 9.1 Comprovar o desenho de plataforma

Os cenários 4, 11 e 12 geram evidências objetivas sobre continuidade, rastreabilidade e recuperabilidade:

- **Queda de PA1**: SP1 e SP2 continuam atendendo, com degradação explícita apenas nos serviços dependentes do DC institucional.
- **Rastreamento de falhas**: métricas, logs e traces mostram causa, impacto e tempo de recuperação.
- **Retorno/equalização**: backlog de backup/sincronização é drenado quando PA1 volta.

Decisões de borda, WAF, IPSEC, DNS, firewall e inspeção TLS permanecem responsabilidade do time de infraestrutura/rede quando a plataforma estiver disponível para validação.

### 9.2 Confirmar dimensionamento

Os cenários 5, 6, 7 e 8 validam que os recursos contratados na EVEO (96 GB RAM, 80 threads por DC) são suficientes para os requisitos não-funcionais.

### 9.3 Refinar runbooks operacionais

Os cenários 3, 4, 5 e 12 produzem runbooks detalhados de failover, recuperação e DR, que servirão de referência para a operação em produção.

### 9.4 Demonstração executiva

Os cenários 4, 8 e 11 produzem **demonstrações visuais** (vídeo, capturas de Grafana) para evidenciar continuidade, escalabilidade e rastreabilidade do projeto.

## 10. Histórico de versões

| Versão | Data | Autor | Mudanças |
|--------|------|-------|----------|
| 1.0 | Abr/2026 | Jeferson Ferreira | Versão inicial |

---

*Este documento é vivo e será atualizado conforme cenários são executados e resultados são incorporados. Eventuais ajustes em hipóteses ou critérios serão registrados no histórico de versões.*

*Mantido pelo CTIC/UNIFESSPA — [github.com/unifesspa-edu-br/uniplus-infra](https://github.com/unifesspa-edu-br/uniplus-infra)*
