# Runbooks Operacionais

> Procedimentos passo-a-passo para operação rotineira e resposta a incidentes da plataforma Uni+.

## Sumário

- [1. Procedimentos Rotineiros](#1-procedimentos-rotineiros)
- [2. Failover e Recuperação](#2-failover-e-recuperação)
- [3. Backup e Restore](#3-backup-e-restore)
- [4. Atualizações](#4-atualizações)
- [5. Resposta a Incidentes](#5-resposta-a-incidentes)
- [6. Operações de Banco](#6-operações-de-banco)
- [7. Diagnóstico](#7-diagnóstico)

## 1. Procedimentos Rotineiros

### 1.1 Verificação diária de saúde

**Quando:** todo dia útil pela manhã, ou após plantões.

**Passos:**

1. Acessar Grafana: `https://grafana.uniplus-lab.shop` (lab) ou `https://grafana.uniplus.unifesspa.edu.br` (prod)
2. Conferir dashboards:
   - **Cluster Health**: pods saudáveis, sem CrashLoop
   - **Database**: replicação Postgres com lag < 5s
   - **Kafka**: consumer lag baixo, ISR completo
   - **MinIO**: nodes operacionais, sem healing pendente
   - **Tráfego**: volume normal, taxa de erro < 0.1%
3. Verificar alertas no Alertmanager (canal de comunicação configurado)
4. Conferir status dos backups da noite anterior

**Tempo estimado:** 5-10 minutos.

### 1.2 Deploy de mudança via GitOps

**Quando:** sempre que houver mudança em manifests/charts a aplicar nos clusters.

**Pré-requisitos:**
- PR aprovado e mergeado em `main`
- Testes locais passaram

**Passos:**

1. Confirmar push em `main`:
   ```bash
   git pull origin main
   ```
2. ArgoCD detecta mudança automaticamente (polling de 3 min) ou via webhook
3. Acompanhar sincronização em `https://argocd.uniplus-lab.shop`
4. Verificar status dos pods atualizados:
   ```bash
   kubectl --context uniplus-sp1 rollout status deployment/<nome>
   kubectl --context uniplus-sp2 rollout status deployment/<nome>
   ```
5. Validar aplicação funcional via smoke tests

**Em caso de falha:** ver [seção 2.6 — Rollback de deploy](#26-rollback-de-deploy).

### 1.3 Adicionar novo segredo no Vault

**Quando:** novo serviço ou rotação de credencial.

**Passos:**

1. Login no Vault:
   ```bash
   vault login
   ```
2. Adicionar segredo:
   ```bash
   vault kv put secret/uniplus/<servico>/<nome> \
       username=<user> \
       password=<pass>
   ```
3. Criar/atualizar `ExternalSecret` no manifest do serviço:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: <servico>-credentials
   spec:
     secretStoreRef:
       name: vault-backend
       kind: ClusterSecretStore
     target:
       name: <servico>-credentials
     data:
       - secretKey: username
         remoteRef:
           key: secret/uniplus/<servico>/<nome>
           property: username
       - secretKey: password
         remoteRef:
           key: secret/uniplus/<servico>/<nome>
           property: password
   ```
4. Commit e push — ArgoCD aplica automaticamente
5. Verificar criação do K8s Secret correspondente:
   ```bash
   kubectl get secret <servico>-credentials -n <namespace>
   ```

## 2. Failover e Recuperação

### Estados operacionais

| Estado | Significado |
|--------|-------------|
| Disponível | Usuários conseguem acessar frontend, autenticar via gov.br/OIDC, chamar APIs e gravar dados operacionais. |
| Degradado | Serviço principal continua disponível, mas alguma capacidade não crítica está pendente, como backup para `PA1`, sincronização LDAP ou agregação central de observabilidade. |
| Indisponível | Fluxo principal do usuário não consegue completar leitura/escrita ou autenticação. |

### 2.1 Failover do PostgreSQL (automático via Patroni)

**Quando:** o primary cai (crash, OOM, falha de hardware).

**Comportamento esperado:** Patroni detecta a falha em ~10s, promove um standby a primary em ~20s. PgBouncer reconfigurado automaticamente. Aplicação reconecta após timeout de connection pool.

**Verificação:**

```bash
# Em qualquer nó com acesso ao Patroni
docker exec patroni-sp1 patronictl list
# ou
patronictl -c /etc/patroni/patroni.yml list

# Saída esperada:
# +--------+----------+--------+---------+----+-----------+
# | Member |   Host   |  Role  |  State  | TL | Lag in MB |
# +--------+----------+--------+---------+----+-----------+
# | sp1    | 10.0.0.1 |Replica | running |  5 |       0   |
# | sp2    | 10.0.0.2 | Leader | running |  5 |           |
# +--------+----------+--------+---------+----+-----------+
```

**Verificar conectividade da aplicação:**

```bash
kubectl logs -n uniplus deploy/api-portal | grep -i "postgres\|connection"
```

**Se falhar:** verificar consenso do Patroni/etcd, incluindo `pa1-consensus-witness` quando essa função estiver ativa.

### 2.2 Failover manual do Postgres

**Quando:** manutenção planejada do primary atual.

```bash
# Promover standby SP2 a primary
patronictl -c /etc/patroni/patroni.yml switchover \
    --master sp1 \
    --candidate sp2 \
    --force
```

### 2.3 Recuperação de DC inteiro (SP1 ou SP2)

**Cenário:** servidor inteiro fica fora (queda de energia, hardware, manutenção EVEO).

**Passos:**

1. **Confirmar a falha**:
   ```bash
   ping uniplus-sp1
   # ou
   ping uniplus-sp2
   ```
2. **Verificar que o outro DC está atendendo**:
   - A entrada HTTP/TLS de lab deve direcionar tráfego ao DC operacional
   - Verificar via `https://uniplus-lab.shop` se o sistema responde
3. **Confirmar promoção do Postgres** (se o DC caído tinha primary):
   ```bash
   patronictl list
   ```
4. **Comunicar ao time** sobre operação em DC único
5. **Aguardar restauração do DC**:
   - Quando voltar, K3s reinicia automaticamente
   - Patroni reincorpora como standby
   - Kafka brokers re-sincronizam
   - MinIO inicia healing
6. **Validar saúde após retorno**:
   ```bash
   ./scripts/validate-cluster.sh
   ```

**Tempo estimado de RTO:** ≤ 1 hora (medido em [VALIDATION-PLAN.md](VALIDATION-PLAN.md) Cenário 5).

### 2.4 PA1 indisponível

**Cenário:** o DC institucional `PA1` fica fora por algumas horas, incluindo `pa1-backup`, `pa1-oidc-source`, LDAP institucional, storage institucional e função de consenso hospedada nele.

**Comportamento esperado:** `SP1` e `SP2` continuam atendendo usuários. Login principal via gov.br/OIDC permanece funcional nos DCs externos. Backup, replicação para `PA1`, sincronização LDAP e retenção central entram em estado **degradado**, com backlog local preservado.

**Passos:**

1. **Confirmar indisponibilidade do PA1**:
   ```bash
   ping uniplus-pa1
   curl -k https://auth.uniplus-lab.shop/realms/unifesspa/.well-known/openid-configuration
   ```
2. **Confirmar atendimento por SP1/SP2**:
   ```bash
   curl -f https://uniplus-lab.shop/portal
   curl -f https://api.uniplus-lab.shop/selecao/health
   curl -f https://api.uniplus-lab.shop/ingresso/health
   ```
3. **Verificar degradações esperadas**:
   - fila/backlog de pgBackRest ou spool de WAL aguardando `pa1-backup`
   - replicação de objetos pendente para `pa1-object-storage`
   - sincronização LDAP/OIDC institucional pendente
   - agregação central de logs/traces com retry
4. **Comunicar estado degradado** ao time, sem tratar como indisponibilidade do sistema se o fluxo principal continuar operacional.
5. **Quando PA1 voltar**, acompanhar equalização:
   ```bash
   # exemplos conceituais; comandos finais serão definidos na implementação
   pgbackrest --stanza=uniplus info
   mc admin replicate status <alias>
   kubectl get pods -A
   ```
6. **Encerrar incidente** apenas quando backlog voltar a zero ou houver plano aceito para pendência residual.

**Critério de recuperação:** `SP1` e `SP2` permanecem disponíveis durante a queda; após retorno de `PA1`, backlog de backup/replicação/sincronização converge sem intervenção destrutiva.

### 2.5 Failover da entrada HTTP/TLS de lab

**Quando:** uma das máquinas (SP1 ou SP2) fica fora.

**Comportamento esperado:** o mecanismo provisório de entrada do laboratório redireciona requisições para o endpoint ativo restante. Esta verificação não valida WAF, DNS institucional, IPSEC, firewall ou inspeção TLS.

**Verificação:**

```bash
# Status do agente de tunnel/entrada local, quando usado
sudo systemctl status cloudflared

# Logs
sudo journalctl -u cloudflared -f
```

**Métricas esperadas:**
- Status do agente de entrada em `SP1` e `SP2`
- Códigos HTTP 2xx/5xx por endpoint
- Latência antes, durante e após a falha

### 2.6 Rollback de deploy

**Quando:** deploy quebrou aplicação ou introduziu bug.

**Opção A — Rollback via Git (recomendado):**

```bash
git revert <commit-id>
git push origin main
# ArgoCD aplica automaticamente
```

**Opção B — Rollback manual via kubectl:**

```bash
# Listar revisões anteriores
kubectl rollout history deployment/<nome> -n <namespace>

# Rollback para revisão anterior
kubectl rollout undo deployment/<nome> -n <namespace>

# Rollback para revisão específica
kubectl rollout undo deployment/<nome> -n <namespace> --to-revision=<n>
```

⚠️ Após rollback manual, ArgoCD vai detectar drift. Faça o rollback no Git também ou ele reverterá novamente.

## 3. Backup e Restore

### 3.1 Backup completo do PostgreSQL

**Frequência configurada:** full semanal (domingos), diferencial diário, WAL contínuo.

**Verificação manual de backups:**

```bash
# Conectar ao container do pgBackRest
docker exec -it pgbackrest sh

# Listar backups
pgbackrest --stanza=uniplus info
```

**Backup ad-hoc (antes de manutenção crítica):**

```bash
docker exec pgbackrest pgbackrest --stanza=uniplus --type=full backup
```

### 3.2 Restore do PostgreSQL

**⚠️ ATENÇÃO:** procedimento destrutivo. Execute em ambiente isolado primeiro.

**Cenário 1 — Restore para mesmo cluster (perda de dados):**

```bash
# Parar aplicações que escrevem
kubectl scale deployment/api-portal --replicas=0 -n uniplus
kubectl scale deployment/api-selecao --replicas=0 -n uniplus
kubectl scale deployment/api-ingresso --replicas=0 -n uniplus

# Parar Postgres
docker compose -f data/postgres/docker-compose.yml stop postgres-portal

# Limpar dados antigos
sudo rm -rf /var/lib/postgres/portal/*

# Restaurar
docker exec pgbackrest pgbackrest --stanza=uniplus_portal restore

# Reiniciar Postgres
docker compose -f data/postgres/docker-compose.yml start postgres-portal

# Validar
docker exec postgres-portal psql -U postgres -c "SELECT count(*) FROM <tabela>;"

# Reativar aplicações
kubectl scale deployment/api-portal --replicas=2 -n uniplus
kubectl scale deployment/api-selecao --replicas=2 -n uniplus
kubectl scale deployment/api-ingresso --replicas=2 -n uniplus
```

**Cenário 2 — Restore Point-In-Time (PITR):**

```bash
docker exec pgbackrest pgbackrest \
    --stanza=uniplus_portal \
    --type=time \
    --target="2026-04-28 14:30:00" \
    restore
```

### 3.3 Backup do Vault

**Frequência configurada:** snapshot diário do storage Raft.

**Snapshot manual:**

```bash
vault operator raft snapshot save /tmp/vault-snapshot-$(date +%Y%m%d).snap
# enviar para storage UNIFESSPA
rsync /tmp/vault-snapshot-*.snap unifesspa-backup:/backups/vault/
```

**Restore:**

```bash
vault operator raft snapshot restore /tmp/vault-snapshot-20260428.snap
```

### 3.4 Backup do MinIO

A replicação contínua para `pa1-object-storage` atua como cópia institucional. Adicionalmente, snapshots noturnos via `mc`:

```bash
mc mirror minio-eveo/aprovado minio-unifesspa/aprovado
```

## 4. Atualizações

### 4.1 Upgrade de aplicação Uni+

**Fluxo padrão (rolling update):**

1. Build de nova imagem Docker via GitHub Actions (CI/CD)
2. Push da imagem para registry
3. PR no `uniplus-infra` atualizando tag da imagem em `apps/<servico>/values.yaml`
4. Merge → ArgoCD aplica → Kubernetes faz rolling update
5. Validação via smoke tests

**Comportamento:** zero downtime se `replicas >= 2` e probes corretas.

### 4.2 Upgrade do Kubernetes (K3s)

**Frequência:** trimestral, ou conforme CVEs críticos.

**Passos (cluster por cluster):**

1. **Anunciar manutenção** (se aplicável)
2. **Backup do etcd K3s:**
   ```bash
   sudo k3s etcd-snapshot save
   ```
3. **Upgrade do K3s no SP2 primeiro:**
   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.31.x+k3s1 sh -
   sudo systemctl restart k3s
   ```
4. **Validar SP2** funcionando, todos os pods Ready
5. **Esperar 1-2 dias** para estabilização
6. **Repetir o processo no SP1**
7. Em caso de problema, restaurar snapshot do etcd

### 4.3 Upgrade do PostgreSQL

**Procedimento:**

1. Verificar release notes da nova versão
2. Backup full antes
3. Upgrade do **standby primeiro** (SP2 se primary está em SP1):
   ```bash
   docker compose -f data/postgres/docker-compose.yml \
       up -d --force-recreate postgres-portal-sp2
   ```
4. Validar standby operacional
5. **Switchover** para promover SP2 a primary:
   ```bash
   patronictl switchover --master sp1 --candidate sp2
   ```
6. Upgrade do antigo primary (agora standby)
7. (Opcional) Switchover de volta

## 5. Resposta a Incidentes

### 5.1 Sistema indisponível (caminho crítico)

**Triagem inicial (primeiros 5 minutos):**

1. Verificar se realmente está fora:
   ```bash
   curl -I https://uniplus-lab.shop
   ```
2. Verificar o mecanismo provisório de entrada HTTP/TLS do lab
3. Verificar dashboards Grafana

**Diagnóstico (próximos 10 minutos):**

```bash
# Pods saudáveis?
kubectl --context uniplus-sp1 get pods -A | grep -v Running
kubectl --context uniplus-sp2 get pods -A | grep -v Running

# Conectividade entre DCs?
ping uniplus-sp2  # da Ryzen
ping uniplus-sp1  # da i7

# Entrada HTTP/TLS de lab?
sudo systemctl status cloudflared

# Bancos saudáveis?
patronictl list
```

**Ação:** identificada a causa, aplicar runbook específico (failover, restart, rollback).

**Comunicação:**
- Notificar time CTIC imediatamente
- Atualizar status page (se aplicável)
- Registrar incident report ao final

### 5.2 Suspeita de invasão / vazamento

**Ação imediata:**

1. **NÃO entrar em pânico** e NÃO desligar serviços impulsivamente
2. **Coletar evidências antes de alterar:**
   ```bash
   # Logs da borda/entrada HTTP/TLS de lab
   
   # Logs Loki
   # Filtrar por status 4xx/5xx anômalos
   
   # Logs sshd
   sudo journalctl -u sshd --since "1 hour ago"
   ```
3. **Bloquear vetor de ataque** sem destruir evidências:
   - Bloquear IPs maliciosos na borda definida para o ambiente
   - Rotação de credenciais expostas
4. **Acionar infraestrutura/rede UNIFESSPA** quando o vetor depender de borda, firewall, DNS ou conectividade institucional
5. **Acionar Encarregado de Dados (DPO)** se houver dados pessoais envolvidos
6. **Documentar timeline** do incidente

### 5.3 Performance degradada

**Sintomas:** latência alta, timeouts, taxa de erro crescente.

**Diagnóstico:**

```bash
# CPU/RAM por pod
kubectl top pods -A

# Slow queries Postgres
docker exec postgres-portal psql -U postgres -d uniplus_portal \
    -c "SELECT query, calls, mean_exec_time FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 10;"

# Lag de replicação
docker exec postgres-portal psql -U postgres \
    -c "SELECT * FROM pg_stat_replication;"

# Consumer lag Kafka
docker exec kafka-broker kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --all-groups
```

**Ações comuns:**
- Escalar réplicas: `kubectl scale deployment/<nome> --replicas=N`
- Restart de pod problemático
- Análise de queries lentas no Postgres
- Aumentar recursos no values do ambiente

## 6. Operações de Banco

### 6.1 Acesso administrativo (read-only) ao Postgres

**⚠️ NUNCA execute UPDATE/DELETE em produção sem aprovação.**

```bash
# Conectar via PgBouncer (read-only role)
psql -h pgbouncer-portal.uniplus.svc -U readonly -d uniplus_portal
```

### 6.2 Migration de schema

**Padrão:** migrations gerenciadas pelo EF Core das APIs .NET.

**Aplicação:**
- Migrations rodam **automaticamente** no startup da aplicação (em ambientes não-produção)
- Em produção, recomenda-se passo manual antes do deploy:
  ```bash
  kubectl exec deploy/api-portal -- dotnet ef database update
  ```

### 6.3 Adicionar nova base/usuário

```bash
docker exec postgres-portal psql -U postgres <<EOF
CREATE DATABASE nova_base;
CREATE USER nova_app WITH PASSWORD 'senha-forte';
GRANT CONNECT ON DATABASE nova_base TO nova_app;
\c nova_base
GRANT USAGE ON SCHEMA public TO nova_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO nova_app;
EOF
```

Persistir no Patroni:

```bash
patronictl edit-config
# adicionar em postgresql.parameters se necessário
```

## 7. Diagnóstico

### 7.1 Comandos úteis no dia a dia

```bash
# Status geral do cluster
kubectl get pods -A
kubectl get events -A --sort-by='.lastTimestamp' | tail -20

# Recursos por nó
kubectl top nodes
kubectl top pods -A --sort-by=cpu

# Logs ao vivo
kubectl logs -f deployment/<nome> -n <namespace>

# Eventos de um pod específico
kubectl describe pod <nome> -n <namespace>

# Troubleshoot DNS
kubectl run --rm -it --image=busybox dns-test -- nslookup kubernetes.default

# Listar Helm releases
helm list -A

# Status de Application no ArgoCD
argocd app list
argocd app get <nome>
```

### 7.2 Coleta de logs para análise

```bash
# Logs centralizados Loki via LogQL
# Acessar Grafana → Explore → datasource Loki

# Exemplo de query: erros das APIs nas últimas 1h
{namespace="uniplus", app=~"api-.*"} |= "error" | json
```

### 7.3 Capturar tráfego (debug avançado)

```bash
# Em uma máquina específica
sudo tcpdump -i any -w /tmp/capture.pcap port 5432

# Analisar com wireshark depois
```

⚠️ **Cuidado:** capturas podem conter dados pessoais. Tratar como informação sensível e descartar após análise.

---

## Apêndice A — Contatos de emergência

| Função | Contato |
|--------|---------|
| Coordenação técnica | Jeferson Ferreira — `jeferson.ferreira@unifesspa.edu.br` |
| Divisão de Redes CTIC | (preencher) |
| Divisão de Sistemas CTIC | (preencher) |
| Diretoria CTIC | (preencher) |
| Suporte EVEO (24/7) | (preencher após contratação) |
| Suporte de borda/DNS | (preencher conforme decisão de infraestrutura/rede) |
| Encarregado de Dados (DPO) | (preencher) |

## Apêndice B — Matriz de criticidade

| Componente | Criticidade | RTO | Notas |
|-----------|-------------|-----|-------|
| API Seleção | 🔴 Crítico | 15 min | Edital ativo = downtime catastrófico |
| API Ingresso | 🟡 Alto | 1 h | Janelas de matrícula |
| API Portal | 🟡 Alto | 2 h | Acesso à informação |
| Frontends | 🟡 Alto | 30 min | Dependência das APIs |
| Postgres | 🔴 Crítico | 15 min | Indisponibilidade total |
| Kafka | 🟠 Médio-alto | 1 h | Eventos podem acumular brevemente |
| MinIO | 🟠 Médio-alto | 2 h | Uploads ficam indisponíveis |
| Keycloak | 🔴 Crítico | 15 min | Sem login = sem sistema |
| Observabilidade | 🟢 Baixo | 24 h | Não afeta usuários |

---

*Documento mantido pelo CTIC/UNIFESSPA. Atualizações via Pull Request.*
