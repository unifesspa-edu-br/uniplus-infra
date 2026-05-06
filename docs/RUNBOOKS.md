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
- [8. Bootstrap e Teardown — Ambiente Standalone OCI](#8-bootstrap-e-teardown--ambiente-standalone-oci)
- [9. Data services no data-host (standalone)](#9-data-services-no-data-host-standalone)

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

### 1.4 Bootstrap inicial do Vault em um ambiente novo

**Quando:** primeira vez que um ambiente (`lab-pa1`, `san-pa1`, `hml-pa1`, `prod-pa1`, ou um cluster `*-sp1`/`*-sp2` novo) recebe o Vault. Operação one-time por ambiente. Para a topologia de fundo, ver [ADR-007](adrs/ADR-007-vault-ha-storage-unseal.md).

**Pré-requisitos:**

- Charts `platform/vault-transit/` (em PA1) e `platform/vault/` (em SP1/SP2) sincronizados pelo ArgoCD. Pods sobem mas ficam selados — esperado.
- Acesso administrativo a `kubectl` nos contextos dos clusters do ambiente.
- Procedimento institucional de guarda de chaves Shamir definido com a DIRSI/CTIC (Apêndice A).

#### A. Bootstrap do Vault Transit em PA1

1. Verificar estado do Pod do Transit (deve estar `Running` mas selado — readiness probe falhando é esperado):
   ```bash
   kubectl --context uniplus-<env>-pa1 -n vault-transit get pods
   ```

2. Inicializar com Shamir 5/3:
   ```bash
   kubectl --context uniplus-<env>-pa1 -n vault-transit exec -it vault-transit-0 -- \
     vault operator init -key-shares=5 -key-threshold=3
   ```
   Output: 5 unseal keys + root token. **Distribuir conforme procedimento institucional** (cofre físico, gestores designados — ver Apêndice A).

3. Unseal manual com 3 dos 5 shares (executar 3 vezes, com shares diferentes):
   ```bash
   kubectl --context uniplus-<env>-pa1 -n vault-transit exec -it vault-transit-0 -- \
     vault operator unseal <share-N>
   ```

4. Login com root token e habilitar a engine Transit + criar a chave de auto-unseal:
   ```bash
   vault login <root-token>
   vault secrets enable transit
   vault write -f transit/keys/autounseal type=aes256-gcm96
   ```

5. Criar policy + token periódico para SP1 e SP2 desbloquearem (token tem renovação automática enquanto Vault SP estiver vivo):
   ```bash
   vault policy write autounseal-sp - <<EOF
   path "transit/encrypt/autounseal" {
     capabilities = ["update"]
   }
   path "transit/decrypt/autounseal" {
     capabilities = ["update"]
   }
   EOF
   vault token create -policy=autounseal-sp -period=8760h -orphan
   ```
   Guardar o token gerado (`<SP_AUTOUNSEAL_TOKEN>`) para o passo B.

#### B. Bootstrap dos Vaults SP1 e SP2

1. Aplicar Secret com o token de auto-unseal no namespace do Vault (não versionar — Secret manual ou via ExternalSecret):
   ```bash
   kubectl --context uniplus-<env>-sp1 -n vault create secret generic vault-transit-token \
     --from-literal=token=<SP_AUTOUNSEAL_TOKEN>
   ```

2. Garantir que o `values.yaml` do environment já tem o bloco `vault.server.seal.transit.address` apontando para o Vault Transit em PA1 (configurado no PR de #13). Reiniciar o StatefulSet para reler a config:
   ```bash
   kubectl --context uniplus-<env>-sp1 -n vault rollout restart statefulset/vault
   ```

3. Inicializar com **Recovery Keys** (auto-unseal já está ativo via Transit, então só recovery keys são geradas — substituem as unseal keys para cenários de DR):
   ```bash
   kubectl --context uniplus-<env>-sp1 -n vault exec -it vault-0 -- \
     vault operator init -recovery-shares=5 -recovery-threshold=3
   ```
   Output: 5 recovery keys + root token. **Guardar conforme procedimento institucional** — recovery keys são a única saída se o Transit em PA1 for perdido (cenário §3.5.D).

4. Validar:
   ```bash
   kubectl --context uniplus-<env>-sp1 -n vault exec -it vault-0 -- vault status
   # esperado: Sealed=false, HA Mode=active em vault-0; standby em vault-1 e vault-2
   ```

5. Repetir os passos 1-4 para SP2.

A partir daqui, restarts de Pods do Vault em SP1/SP2 (manutenção, reboot do node, rolling update) acontecem sem intervenção humana — o auto-unseal Transit cuida.

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
   curl -f http://uniplus-pa1:18080/realms/unifesspa/.well-known/openid-configuration
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

**Frequência configurada:** snapshot diário do storage Raft, em todos os Vaults (Transit em PA1 e Vaults de aplicação em SP1/SP2). Destino: `pa1-backup`.

**Snapshot manual:**

```bash
vault operator raft snapshot save /tmp/vault-snapshot-$(date +%Y%m%d).snap
# enviar para storage UNIFESSPA
rsync /tmp/vault-snapshot-*.snap unifesspa-backup:/backups/vault/
```

**Restore (caso simples — Pod ou cluster SP perdido):**

```bash
vault operator raft snapshot restore /tmp/vault-snapshot-20260428.snap
```

> **Observação sobre restore.** O comportamento difere conforme o que está sendo restaurado:
>
> - **Restore em SP1/SP2** com Transit em PA1 intacto: após `restore`, o auto-unseal Transit destrava sozinho. Sem intervenção manual.
> - **Restore no Transit em PA1**: após `restore`, o Transit volta selado. É preciso reentrar 3 dos 5 shares Shamir originais (procedimento §1.4.A passo 3).
> - **Perda do Transit + perda do snapshot do Transit**: cenário catastrófico. Ver §3.5.D.

### 3.4 Backup do MinIO

A replicação contínua para `pa1-object-storage` atua como cópia institucional. Adicionalmente, snapshots noturnos via `mc`:

```bash
mc mirror minio-eveo/aprovado minio-unifesspa/aprovado
```

### 3.5 Disaster Recovery do Vault

Cenários ordenados por gravidade. O caminho A é cotidiano; D é o cenário extremo a ser evitado a todo custo.

**A. Perda de um Pod do Vault em SP1 ou SP2 (caso comum).** O StatefulSet recria o Pod; auto-unseal Transit destrava automaticamente. Sem intervenção. Apenas validar que o Pod voltou ao estado `Running` e que o Vault no cluster mantém quórum Raft.

**B. Perda completa do cluster Vault em SP1 ou SP2 (cluster K3s reprovisionado).** Transit em PA1 está intacto.

1. Garantir que o cluster K3s está sincronizado pelo ArgoCD com o chart `platform/vault/`.
2. Recriar o Secret `vault-transit-token` (passo §1.4.B.1).
3. Restaurar o snapshot Raft mais recente:
   ```bash
   kubectl --context uniplus-<env>-sp1 -n vault exec -it vault-0 -- \
     vault operator raft snapshot restore /backups/vault-snapshot-<data>.snap
   ```
4. Auto-unseal Transit destrava os 3 Pods em sequência. Validar com `vault status`.

**C. Perda completa do Vault Transit em PA1 (snapshot disponível).** Vaults SP que já estão unselados continuam servindo, **mas qualquer restart de Pod do Vault em SP trava** até o Transit voltar.

1. Reprovisionar K3s em PA1 + ArgoCD sincroniza `platform/vault-transit/`.
2. Restaurar o snapshot do Transit:
   ```bash
   vault operator raft snapshot restore /backups/vault-transit-snapshot-<data>.snap
   ```
3. Após o restore, o Transit volta selado. Reentrar 3 shares Shamir (§1.4.A passo 3).
4. Validar que `transit/keys/autounseal` está acessível e tem o material criptográfico original (mesmo `version` antes e depois). Sem isso, Pods de Vault em SP não conseguirão unseal.

**D. Perda do Transit + perda do snapshot do Transit (catastrófico).** A chave `autounseal` é irrecuperável. Caminho de recovery:

1. Bootstrap de um novo Vault Transit em PA1 (procedimento §1.4.A inteiro). Gera nova chave `autounseal` e novo `<SP_AUTOUNSEAL_TOKEN>`.
2. Em cada Vault SP, destravar manualmente com **recovery keys** (geradas no init original do Vault SP — §1.4.B passo 3):
   ```bash
   vault operator unseal <recovery-key-1>
   vault operator unseal <recovery-key-2>
   vault operator unseal <recovery-key-3>
   ```
3. Atualizar o Secret `vault-transit-token` em cada cluster SP com o novo token gerado no passo 1.
4. Atualizar config de seal apontando para o novo Transit (caso o endpoint tenha mudado).
5. Reiniciar os Pods. Próximos restarts usarão o novo Transit normalmente.

> **Princípio de guarda de chaves (LGPD + soberania):**
>
> - **Unseal keys do Transit (PA1):** 5 shares Shamir, threshold 3, distribuídos entre 5 gestores designados (Apêndice A).
> - **Recovery keys dos Vaults SP1/SP2:** 5 shares cada, threshold 3, **guardadas em cofre distinto** dos shares do Transit. Perder ambos os conjuntos = secret store irrecuperável (rotação completa de credenciais).
> - **Snapshots Raft em `pa1-backup`** ficam criptografados em repouso. Restore exige acesso ao próprio Vault (`vault operator raft snapshot restore` valida assinatura interna).

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

## 8. Bootstrap e Teardown — Ambiente Standalone OCI

Ambiente de homologação e produção inicial composto por dois hosts Ubuntu na OCI:

| Host | Papel | IP público | IP privado |
|------|-------|-----------|-----------|
| `k8s-host` | K3s single-node + Helm + ArgoCD | `164.152.53.29` | — |
| `data-host` | Docker + LVM (Postgres, Kafka, MinIO, Vault, Redis) | — | `10.0.2.87` |

> Pré-requisito: chave SSH `~/.ssh/id_ed25519` com acesso a ambos os hosts como usuário `ubuntu`.

### 8.1 Bootstrap do k8s-host

**Quando:** primeira configuração do ambiente ou após teardown completo.

**Executar no k8s-host:**

```bash
# Clonar o repositório (se ainda não estiver presente)
git clone https://github.com/unifesspa-edu-br/uniplus-infra.git
cd uniplus-infra

# Dry-run primeiro — verificar o que será feito
./scripts/bootstrap-standalone.sh --role=standalone-k8s --dry-run

# Executar (instala K3s, Helm e ArgoCD)
./scripts/bootstrap-standalone.sh --role=standalone-k8s
```

**Flags disponíveis:**
- `--skip-k3s` — pular instalação do K3s (útil se K3s já estiver instalado)
- `--dry-run` — mostrar ações sem executar

**Validação imediata após bootstrap:**

```bash
# K3s operacional
kubectl get nodes
kubectl get pods -n kube-system

# ArgoCD operacional
kubectl get pods -n argocd
```

**Tempo estimado:** 5–10 minutos (depende da velocidade de download dos binários).

### 8.2 Bootstrap do data-host

> **Postgres 18:** codificado no bootstrap (ver §9.1). Kafka, MinIO e Redis ainda dependem de sub-tasks da Epic `data/*` — volumes LVM já são provisionados, containers + systemd units serão adicionados conforme o mesmo padrão do Postgres.

**Executar no data-host (via SSH do k8s-host):**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87

# Dentro do data-host:
git clone https://github.com/unifesspa-edu-br/uniplus-infra.git
cd uniplus-infra

# Dry-run
./scripts/bootstrap-standalone.sh --role=standalone-data --dry-run

# Executar (instala Docker, configura LVM e monta volumes)
./scripts/bootstrap-standalone.sh --role=standalone-data
```

**Flags disponíveis:**
- `--skip-docker` — pular instalação do Docker
- `--dry-run` — mostrar ações sem executar

**Topologia de volumes esperada** (verificar com `lsblk` antes de rodar):

| Volume OCI | Tamanho | VG | Mount point |
|-----------|---------|-----|-------------|
| Block volume 1 | 50 GB | `vg-vault` | `/var/lib/uniplus/vault` |
| Block volume 2 | 100 GB | `vg-kafka` | `/var/lib/uniplus/kafka` |
| Block volume 3 | 200 GB | `vg-postgres` | `/var/lib/uniplus/postgres` |
| Block volume 4 | 200 GB | `vg-minio` | `/var/lib/uniplus/minio` |

### 8.3 Registro do cluster no ArgoCD

> Procedimento detalhado a ser documentado em #85. Resumo:

```bash
# No k8s-host, autenticar no ArgoCD e registrar o cluster local
argocd login localhost:8080 --insecure --username admin --password <senha-inicial>

# O kubeconfig do K3s aponta para o cluster local — registrar como "standalone"
argocd cluster add default --name uniplus-standalone --in-cluster
```

Após o registro, o ApplicationSet em `argocd/applicationset.yaml` detecta o cluster pelo label e inicia a sincronização.

### 8.4 Init, unseal e configuração do Vault (Shamir manual)

> **Decisão arquitetural temporária (2026-05-05):** standalone usa **Shamir seal com unseal manual** em vez de OCI KMS auto-unseal. OCI KMS provisionado e pronto, mas Vault 1.20.x/1.21.x panicam consistentemente em `go-kms-wrapping@v2.0.9/ocikms.go:290` na pre-flight encrypt validation (Resource Principal *e* API Key falham; OCI CLI direto funciona — bug é no Vault, não na infra). Migração para `seal "ocikms"` quando Vault 1.22+ chegar com go-kms-wrapping atualizado. Detalhes do bloco `seal` provisional em `environments/standalone/values.yaml` (comentário no chart vault).

#### 8.4.1 Init na primeira vez

```bash
# 1) Verificar que o Vault está running mas não inicializado:
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec platform-vault-uniplus-standalone-0 -- vault status
# Esperado: Initialized=false, Sealed=true

# 2) Inicializar com Shamir 5/3 (5 shares, threshold 3).
#    Criar o arquivo destino COM mode 0600 ANTES do redirect — evita
#    janela de exposição em que o init output (com 5 unseal keys + root
#    token) ficaria legível por outros usuários do host até o chmod rodar.
INIT_FILE=$(mktemp -t vault-init.XXXXXX.json)
chmod 600 "$INIT_FILE"
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec platform-vault-uniplus-standalone-0 -- \
  vault operator init -format=json -key-shares=5 -key-threshold=3 \
  > "$INIT_FILE"
echo "Init output em $INIT_FILE — exportar para gestor institucional e shred."
```

> ⚠️ **CRÍTICO — guarda das keys.** O comando acima imprime as 5 unseal keys e o root token **uma única vez**. Custodiar imediatamente em gestor institucional (Bitwarden, 1Password ou Vault corporativo separado). Após exportar, **deletar com `shred -u "$INIT_FILE"`** — não deixar em disco do host.
>
> Em caso de perda das 3 das 5 keys (threshold), o Vault fica selado permanentemente. Em standalone isso é recuperável re-bootstrappeando (perde os secrets do Vault — aceitável porque o overlay é descartável). Em prod 3-DC seria catastrófico — por isso prod usa Transit auto-unseal, não Shamir.

#### 8.4.2 Unseal manual (após cada Pod restart)

Cada vez que o Pod do Vault reinicia (upgrade K3s, manutenção da VM, OOMKill etc.) o Vault sobe `Sealed=true` e exige 3 das 5 unseal keys para destravar. **Não é one-shot — é um procedimento operacional recorrente em standalone.**

> **Pré-requisito**: HashiCorp `vault` CLI instalada na workstation do operador (`brew install vault` / pacote oficial). Os blocos abaixo evitam expandir as unseal keys em argv de `kubectl exec` (que vazaria via `/proc/<pid>/cmdline`, `ps`, auditoria) — em vez disso, conectamos `vault` CLI local ao Vault via port-forward e passamos cada share por **stdin** (`vault operator unseal -`).

```bash
# 1) Port-forward local do Vault + apontar a CLI (mesmo pattern de §8.4.3)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset K1 K2 K3 VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200

# Aguardar port-forward subir
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

# 2) Ler 3 das 5 keys do gestor institucional (sem echo, sem history).
#    Cada `read -rs` desabilita o eco (chave não aparece no terminal) e
#    NÃO vai para ~/.bash_history.
read -rsp "Unseal Key 1: " K1; echo
read -rsp "Unseal Key 2: " K2; echo
read -rsp "Unseal Key 3: " K3; echo

# 3) Unseal via stdin do `vault operator unseal -` — chave NÃO entra em argv,
#    invisível em /proc/<pid>/cmdline. Após 3 shares válidas, Sealed=false.
for K in "$K1" "$K2" "$K3"; do
  printf '%s\n' "$K" | vault operator unseal -
done
unset K K1 K2 K3
history -c 2>/dev/null || true

# 4) Confirmar:
vault status | grep Sealed
# Esperado: Sealed          false

# trap EXIT ao sair do shell encerra port-forward + cleanup das envs
```

#### 8.4.3 Configuração inicial pós-unseal (Kubernetes auth + ESO role)

Executar **uma vez** após o init, com o root token recém-emitido. Após esse setup, External Secrets passa a autenticar no Vault via ServiceAccount JWT — sem precisar de root token nas Apps.

> **Nota de higiene de credenciais.** Os blocos abaixo evitam expandir o root token em argv de comandos (`kubectl exec ... sh -c "...$TOKEN..."` colocaria o token em `/proc/<pid>/cmdline`, visível em `ps`/auditoria). Em vez disso, abrimos um port-forward local e exportamos `VAULT_TOKEN` apenas no shell do operador — o token fica na memória do shell + processo `vault`, sem cruzar argv de outros processos.

```bash
# 1) Port-forward local do Vault (background; trap para cleanup)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR' EXIT

# 2) Apontar a CLI vault para o port-forward
export VAULT_ADDR=http://127.0.0.1:8200

# Aguardar port-forward subir
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

# 3) Ler root token interativamente (sem echo, sem history)
read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

# 4) Habilitar Kubernetes auth method
vault auth enable kubernetes

# 5) Apontar para o API server interno (token reviewer usa SA do próprio Pod)
vault write auth/kubernetes/config \
  kubernetes_host=https://kubernetes.default.svc.cluster.local

# 6) Policy de leitura no KV v2 (path `secret/`)
vault policy write external-secrets-read - <<'POLICY'
path "secret/data/*" { capabilities = ["read"] }
path "secret/metadata/*" { capabilities = ["read"] }
POLICY

# 7) Role vinculando ServiceAccount external-secrets/external-secrets à policy
vault write auth/kubernetes/role/external-secrets \
  bound_service_account_names=external-secrets \
  bound_service_account_namespaces=external-secrets \
  policies=external-secrets-read \
  ttl=24h

# 8) Habilitar KV v2 em `secret/` (não vem montado por default em HA Raft)
vault secrets enable -path=secret -version=2 kv

# trap EXIT cuida do unset + kill — sair do shell encerra a sessão
```

#### 8.4.4 Validação end-to-end (ClusterSecretStore + ExternalSecret)

> Mesmo padrão de higiene da §8.4.3: port-forward + `VAULT_TOKEN` em env do shell local. O `trap EXIT` definido na §8.4.3 já cuida do cleanup; se você abriu uma nova sessão para esta validação, refazer os passos 1-3 da §8.4.3 antes.

```bash
# 1) Confirmar ClusterSecretStore Valid + Ready:
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml get clustersecretstore vault-default
# Esperado: STATUS=Valid, READY=True

# 2) PUT secret de teste no Vault (token vem do env, não do argv):
vault kv put secret/test/eso-validation \
  message=hello \
  timestamp="$(date -u +%FT%TZ)"

# 3) Criar ExternalSecret consumer (default ns, refresh 1m):
cat <<'EOF' | sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f -
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: eso-validation
  namespace: default
spec:
  refreshInterval: 1m
  secretStoreRef: { name: vault-default, kind: ClusterSecretStore }
  target: { name: eso-validation, creationPolicy: Owner }
  data:
    - secretKey: message
      remoteRef: { key: test/eso-validation, property: message }
EOF

# 4) Conferir Secret sintetizado em ~10-30s:
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n default get externalsecret eso-validation
# Esperado: STATUS=SecretSynced, READY=True

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n default get secret eso-validation -o jsonpath='{.data.message}' | base64 -d
# Esperado: hello

# 5) Cleanup:
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n default delete externalsecret eso-validation
vault kv metadata delete secret/test/eso-validation
# Sair do shell (ou explicitamente):
exit  # dispara o trap EXIT da §8.4.3 → kill port-forward + unset VAULT_TOKEN VAULT_ADDR
```

#### 8.4.5 Migração futura para OCI KMS auto-unseal

Quando Vault 1.22+ aterrissar (go-kms-wrapping atualizado), a migração elimina o procedimento manual de unseal:

1. Adicionar bloco `seal "ocikms"` em `vault.server.ha.raft.config` (override standalone), apontando para o OCI Vault + Master Key já provisionados (OCIDs em `environments/standalone/values.yaml` — comentário do chart vault).
2. Provisionar Secret `vault-ocikms-config` via ESO/Vault (será emitido pelo próprio Vault standalone via `secret/data/standalone/ocikms`).
3. `vault operator migrate` para converter Shamir → OCI KMS.
4. Restart do StatefulSet — Pod sobe com `Sealed=false` automaticamente.

Validar antes em ambiente de teste com `letsencrypt-staging` cert do Vault (qualquer regressão fica rasteada). Não migrar em prod sem validação no lab.

### 8.5 Validação completa do ambiente

**Executar no k8s-host após todos os bootstraps:**

```bash
# Usando o IP padrão do data-host (10.0.2.87)
./scripts/validate-standalone.sh

# Sobrepor IP se necessário
DATA_HOST_IP=10.0.2.87 ./scripts/validate-standalone.sh
```

**Saída esperada em ambiente completo:**

```
============================================
  Resumo: X OK, 0 ERROS, Y AVISOS
============================================
```

Avisos são esperados enquanto serviços da Epic `data/*` ainda não estiverem provisionados (Vault não inicializado, containers de dados não rodando).

**Critério de sucesso:** `0 ERROS` nos checks críticos (K3s, kubectl, ArgoCD, SSH ao data-host).

### 8.6 Teardown do k8s-host

**Quando:** re-provisionar o ambiente standalone ou liberar recursos.

```bash
# Executar no k8s-host
./scripts/teardown-lab.sh --role=standalone-k8s
```

**O que é removido:**
- K3s e todo o estado do cluster (pods, PVs, namespaces)
- `~/.kube/config`
- Helm binário (`/usr/local/bin/helm`)
- cloudflared (se ativo)

**O que é preservado:** volumes LVM do data-host ficam intactos.

**Pós-teardown:** re-bootstrap via `./scripts/bootstrap-standalone.sh --role=standalone-k8s`.

### 8.7 Teardown do data-host

**Quando:** encerrar o ambiente de dados ou preparar re-provisionamento.

```bash
# A partir do k8s-host — SSH no data-host e executar teardown
ssh -t -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87 \
  "cd uniplus-infra && ./scripts/teardown-lab.sh --role=standalone-data"
```

**O que é removido:**
- Todos os containers Docker (stop + rm)
- Volumes Docker (`docker volume prune`)
- Pontos de montagem LVM (`/var/lib/uniplus/{postgres,kafka,minio,vault}` são desmontados)
- Entradas dos VGs no `/etc/fstab`

**O que é preservado:** dados nos block volumes OCI — o LVM fica intacto, apenas desmontado. Re-montagem pelo bootstrap recupera os dados.

**Pós-teardown:** re-bootstrap via `./scripts/bootstrap-standalone.sh --role=standalone-data`.

## 9. Data services no data-host (standalone)

Em standalone, os componentes stateful rodam **fora do K8s** — containers Docker gerenciados por `systemd` no data-host. A primeira entrega da Epic `data/*` codifica o Postgres 18; Kafka, MinIO e Redis seguirão o mesmo padrão.

### 9.1 Postgres 18 — bootstrap automatizado

A função `step_data_setup_postgres` em `scripts/bootstrap-standalone.sh` provisiona, na ordem:

1. Diretórios `/var/lib/uniplus/postgres/{data,init}` com ownership `70:70` (uid `postgres` no container `postgres:18-alpine` — Alpine usa uid 70, distinto do uid 999 das imagens Debian-based).
2. `.bootstrap-creds` (root:root 600) em `/var/lib/uniplus/postgres/.bootstrap-creds` com `super_pw` + `keycloak_pw` (256 bits cada via `openssl rand -hex 32`) — gerado **somente na primeira execução**.
3. Init SQL **efêmero** `/var/lib/uniplus/postgres/init/00-keycloak.sql` (mode `600`, owner `70:70`) — gerado APENAS quando o cluster ainda não foi inicializado (sem `PG_VERSION` em `data/`). Cria role `keycloak` + database `keycloak` na primeira inicialização. Após `pg_isready` confirmar que o entrypoint executou o script, o arquivo é shredded (`shred -u`) — `keycloak_pw` em cleartext NÃO persiste no filesystem do data-host entre runs (snapshots/backups da LVM `vg-postgres` não capturam cópia extra do secret).
4. EnvironmentFile `/etc/uniplus-postgres.env` (root:root 600) com `POSTGRES_PASSWORD=<super_pw>` lido do `.bootstrap-creds`. `docker run` recebe a senha via `-e POSTGRES_PASSWORD` (sem `=value`) — evita exposure em `/proc/<pid>/cmdline`.
5. `systemd` unit `/etc/systemd/system/uniplus-postgres.service` com `Restart=always`, `Type=simple`, container em `--network host` (Postgres listen em `10.0.2.87:5432`).

**Idempotência (decisões independentes):**

- `.bootstrap-creds`: se já existe, preserva; se não existe e cluster já inicializado, aborta apontando §9.4; senão, gera novas senhas.
- Init SQL: regenerado sempre que o cluster ainda não tem `PG_VERSION` (cobre o fluxo §9.4 — restore creds, data dir vazio → SQL recriado a partir do `keycloak_pw` persistido). Cleanup defensivo se leftover persiste após cluster já estar inicializado.
- EnvironmentFile + systemd unit: sempre re-aplicados (cheap, corrige drift sem afetar state do cluster).
- Serviço já ativo: bootstrap não reinicia (evita downtime).

**Verificação imediata pós-bootstrap:**

```bash
sudo systemctl status uniplus-postgres
sudo docker exec uniplus-postgres pg_isready -U postgres
sudo docker exec uniplus-postgres psql -U keycloak -d keycloak -c 'SELECT current_user, current_database();'
# Esperado: keycloak | keycloak
```

### 9.2 Custódia das senhas iniciais

> ⚠️ **CRÍTICO.** O `.bootstrap-creds` é o **único rastro em disco** das senhas geradas. Custodiar imediatamente em gestor institucional + Vault standalone, depois `shred -u` o arquivo.

**Passo 1 — Ler senhas no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo cat /var/lib/uniplus/postgres/.bootstrap-creds
# super_pw=<64 hex>
# keycloak_pw=<64 hex>
```

Salvar `keycloak_pw` no gestor institucional (Bitwarden, 1Password ou Vault corporativo separado). O `super_pw` pode ser descartado após o setup — é a senha do superuser `postgres`, usada apenas em break-glass; recuperável via re-bootstrap se necessário.

**Passo 2 — Salvar `keycloak_pw` no Vault standalone (executar do k8s-host):**

> Mesmo padrão de higiene da §8.4.3: port-forward + token via env do shell, não argv.

```bash
# 1) Ler keycloak_pw do data-host (ssh, sem cruzar argv local)
read -rsp "Cole keycloak_pw (do passo 1): " KC_PW; echo

# 2) Port-forward Vault
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset KC_PW VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

# 3) Root token (sem echo, sem history)
read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

# 4) PUT em secret/standalone/postgres/keycloak (KV v2)
vault kv put secret/standalone/postgres/keycloak \
  host=10.0.2.87 \
  port=5432 \
  database=keycloak \
  username=keycloak \
  password="$KC_PW"

# 5) Confirmar
vault kv get secret/standalone/postgres/keycloak
# Esperado: campos host/port/database/username/password presentes

# trap EXIT cuida de kill + unset ao sair do shell
```

**Passo 3 — Limpar `.bootstrap-creds` no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo shred -u /var/lib/uniplus/postgres/.bootstrap-creds
```

> ⚠️ Após `shred -u`, re-execução do bootstrap **regeneraria** as senhas (não há outro rastro em disco). Se for necessário re-rodar o script com data dir já populado, restaurar o `.bootstrap-creds` antes a partir do gestor institucional (ver §9.4).

### 9.3 Validação end-to-end (pod K8s → Postgres)

Confirma que pods do cluster K3s alcançam o Postgres no data-host via TCP. Pré-requisito: PR #125 aplicado (iptables FORWARD ACCEPT entre flannel CIDR e VCN).

**Executar no k8s-host:**

```bash
# 1) Conectividade TCP bruta
nc -zv 10.0.2.87 5432
# Esperado: succeeded

# 2) Senha do keycloak — fail fast se não disponível.
#    Após §9.2 shred, .bootstrap-creds não existe mais; restaure via §9.4
#    antes de rodar este bloco (ou cole a senha à mão via read -rsp).
KEYCLOAK_PW=$(ssh ubuntu@10.0.2.87 \
  "sudo grep keycloak_pw= /var/lib/uniplus/postgres/.bootstrap-creds 2>/dev/null | cut -d= -f2")
if [ -z "$KEYCLOAK_PW" ]; then
  echo "ERRO: keycloak_pw não encontrado em .bootstrap-creds no data-host." >&2
  echo "  - Se .bootstrap-creds foi shredded (§9.2), restaure via §9.4 antes" >&2
  echo "    OU cole a senha manualmente: read -rsp 'keycloak_pw: ' KEYCLOAK_PW; echo" >&2
  return 1 2>/dev/null || exit 1
fi

# 3) Pod ad-hoc com psql (sem hostNetwork — usa flannel).
#    Senha vai via stdin (here-string + `read -r` no pod), NÃO em argv:
#    - `<<<` é processada pelo bash sem fork → senha não cruza argv do shell
#      local nem aparece em /proc/<pid>/cmdline do k8s-host.
#    - `kubectl run -i` conecta o stdin do bash ao stdin do container.
#    - Dentro do pod, `read -r PW` consome a linha; `PGPASSWORD="$PW"` fica
#      apenas no env do processo psql, NUNCA na spec do Pod salva no apiserver.
#    Mesmo padrão de higiene de §8.4.2 (unseal keys via stdin do vault CLI).
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml run pg-validation \
  --image=postgres:18-alpine --restart=Never --rm -i --command -- \
  sh -c 'read -r PW; PGPASSWORD="$PW" psql -h 10.0.2.87 -U keycloak -d keycloak -c "SELECT 1 AS ok;"' \
  <<<"$KEYCLOAK_PW"
# Esperado: 1 (uma linha)
unset KEYCLOAK_PW
```

Se o pod fica preso em `Pending` ou retorna `Host is unreachable`: revisar §8.6/§8.7 do plano-pai (#123) e confirmar que `iptables -L FORWARD` no k8s-host mostra os ACCEPTs flannel↔VCN antes do `REJECT --reject-with icmp-host-prohibited`.

### 9.4 Restore: re-criar `.bootstrap-creds` a partir do Vault

Caso o operador tenha rodado `shred -u` e precise re-executar o bootstrap (ou recuperar a senha localmente para troubleshooting), recriar o arquivo a partir do Vault:

```bash
# No k8s-host — port-forward + leitura do secret (mesmo pattern §9.2)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset KC_PW VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

KC_PW=$(vault kv get -field=password secret/standalone/postgres/keycloak)

# Transmitir para o data-host via stdin do ssh — não cruza argv
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87 \
  "sudo tee /var/lib/uniplus/postgres/.bootstrap-creds > /dev/null && \
   sudo chmod 600 /var/lib/uniplus/postgres/.bootstrap-creds && \
   sudo chown root:root /var/lib/uniplus/postgres/.bootstrap-creds" <<EOF
super_pw=<recuperar do gestor institucional, ou regenerar via ALTER USER postgres>
keycloak_pw=$KC_PW
EOF

# Cleanup automático via trap
```

> O `super_pw` não é persistido no Vault (intencional — só é usado em break-glass do superuser). Se realmente necessário, recuperar do gestor institucional ou regenerar via `ALTER USER postgres WITH PASSWORD '...'` antes de re-rodar o bootstrap.

**Após reconstituir `.bootstrap-creds`:** rodar `./scripts/bootstrap-standalone.sh --role=standalone-data` no data-host. Se o data dir do Postgres estiver vazio (ex.: re-provisionamento da LVM), o bootstrap detecta e regenera `00-keycloak.sql` a partir do `keycloak_pw` recém-restaurado, deixa o Postgres inicializar o cluster e shred o SQL após `pg_isready`. Se o cluster já estiver inicializado, o SQL não é gerado (cluster preserva role/db criados originalmente) — o bootstrap apenas re-aplica EnvironmentFile/systemd unit.

### 9.5 Backup e Restore do cluster Postgres

> Procedimento detalhado a ser codificado em sub-task da Epic `data/*` (paralelo à 3.4 MinIO). Resumo:
>
> - **Backup:** `pg_dump --format=custom keycloak` rodado periodicamente via systemd timer no data-host, output enviado para bucket MinIO (`s3://backups/postgres/<timestamp>.dump`).
> - **Restore:** `pg_restore --clean --if-exists --no-owner --dbname=keycloak <dump>` em data-host com volume LVM intacto.

## 10. Keycloak (standalone)

Operações do serviço OIDC local em standalone — chart `apps/keycloak-replica/`. Pré-requisito: §9 Postgres systemd ativo no data-host + Vault unsealed + ESO `ClusterSecretStore vault-default` STATUS=Valid+Ready.

### 10.1 Pré-flight: secrets no Vault

Antes do ArgoCD reconciliar o chart, persistir as 3 credenciais consumidas via ExternalSecret. O Postgres já está coberto pela §9.2; falta o admin do Keycloak e o client secret do `uniplus-portal`:

```bash
# No k8s-host — port-forward + autenticação (mesmo pattern §9.2)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset VAULT_TOKEN VAULT_ADDR ADMIN_PW CLIENT_SECRET' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

# 1) Bootstrap admin — gera senha aleatória (32 bytes hex), persiste e custodia
ADMIN_PW=$(openssl rand -hex 32)
vault kv put secret/standalone/keycloak/admin \
  username=admin password="$ADMIN_PW"
echo "Admin password (salvar no gestor institucional): $ADMIN_PW"

# 2) Client secret do uniplus-portal — também aleatório (será setado no realm
#    via ${VAR} substitution; rotação posterior via kcadm.sh, ver §10.4)
CLIENT_SECRET=$(openssl rand -hex 32)
vault kv put secret/standalone/keycloak/clients/uniplus-portal \
  client_id=uniplus-portal client_secret="$CLIENT_SECRET"
echo "Client secret (salvar no gestor institucional): $CLIENT_SECRET"

# trap EXIT cuida de kill + unset ao sair do shell
```

> ⚠️ **Custódia:** salvar `ADMIN_PW` e `CLIENT_SECRET` em gestor institucional (Bitwarden, 1Password, Vault corporativo). Standalone não é cofre durável — re-bootstrap via Tofu pode regenerar Shamir keys e perder estes secrets. Rotacionar via §10.4 antes de promover para hml/prod.

### 10.2 Verificar pod e ESO

```bash
kc() { sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }

# 1) ExternalSecrets sintetizaram os Secrets K8s
kc get externalsecret -n uniplus
# Esperado: 3 ESOs com STATUS=SecretSynced READY=True
#   - keycloak-replica-uniplus-standalone-db
#   - keycloak-replica-uniplus-standalone-bootstrap-admin
#   - keycloak-replica-uniplus-standalone-client-uniplus-portal

# 2) Pod Running 1/1
kc get pod -n uniplus -l app.kubernetes.io/name=keycloak-replica
# Esperado: keycloak-replica-uniplus-standalone-<hash>  1/1  Running

# 3) Logs limpos (sem erros DB connection, sem realm-import error)
kc logs -n uniplus -l app.kubernetes.io/name=keycloak-replica --tail=200

# 4) Probes na management port (9000) respondem
kc exec -n uniplus -l app.kubernetes.io/name=keycloak-replica -- \
  curl -sf http://localhost:9000/health/ready
# Esperado: {"status": "UP", "checks": [...]}
```

### 10.3 Smoke test end-to-end

Do laptop (sem precisar de SSH):

```bash
# 1) Discovery OIDC
curl -sk https://standalone.portaluni.com.br/auth/realms/uniplus/.well-known/openid-configuration \
  | jq '.issuer, .authorization_endpoint, .token_endpoint'
# Esperado: issuer = "https://standalone.portaluni.com.br/auth/realms/uniplus"

# 2) Admin console (UI) — aceitar warning de cert (Let's Encrypt staging)
xdg-open https://standalone.portaluni.com.br/auth/admin/

# 3) Login com admin user lido do Vault (§10.1) — realm `uniplus` deve
#    aparecer no dropdown superior esquerdo + client `uniplus-portal`
#    visível em "Clients" com Authorization Code + PKCE habilitado
```

### 10.4 Rotacionar client secret do `uniplus-portal`

Quando necessário (comprometimento, política de rotação periódica):

```bash
# 1) Gerar novo secret e atualizar Vault primeiro
NEW_SECRET=$(openssl rand -hex 32)
vault kv put secret/standalone/keycloak/clients/uniplus-portal \
  client_id=uniplus-portal client_secret="$NEW_SECRET"

# 2) Forçar refresh do ExternalSecret (espera até refreshInterval=1h ou refresh imediato)
kc annotate externalsecret -n uniplus \
  keycloak-replica-uniplus-standalone-client-uniplus-portal \
  force-sync="$(date +%s)" --overwrite

# 3) Aplicar no Keycloak via kcadm.sh (realm-import só cria; rotação é via API).
#    NEW_SECRET vai via stdin (here-string + `read -r` no pod) — NUNCA em argv,
#    evitando exposure em /proc/<pid>/cmdline e a armadilha clássica de
#    quoting (single vs. double quotes em `bash -c`). O password de admin
#    vem do env var KC_BOOTSTRAP_ADMIN_PASSWORD que já existe no Pod
#    (envFrom da ExternalSecret keycloak-bootstrap-admin).
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  read -r NEW_SECRET
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"
  CLIENT_UUID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus \
    -q clientId=uniplus-portal --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh update "clients/$CLIENT_UUID" -r uniplus \
    -s "secret=$NEW_SECRET"
' <<<"$NEW_SECRET"
unset NEW_SECRET

# 4) Atualizar configuração dos consumers (apps que usam o client) — via redeploy
#    quando os apps reais aterrissarem (Fase 5)
```

### 10.5 Re-importar realm (forçar replace)

Por padrão o `--import-realm` em 26.x **pula** se o realm já existir, preservando mudanças via Admin UI. Para forçar reimport (perde mudanças não commitadas no `uniplus-realm.json`):

> ⚠️ **Pré-requisito: Keycloak parado.** `kc.sh import --override` exige que **nenhum nó esteja rodando** (doc oficial Keycloak 26.x — port conflicts e state inconsistente se executado contra server live). Procedimento abaixo escala o Deployment para 0, roda um Job descartável de import, depois escala de volta.

```bash
# 1) Scale-down do Deployment + aguardar pods sumirem
kc scale deployment -n uniplus keycloak-replica-uniplus-standalone --replicas=0
kc wait pod -n uniplus -l app.kubernetes.io/name=keycloak-replica \
  --for=delete --timeout=120s

# 2) Job ad-hoc rodando `kc.sh import --override` offline. Mesma imagem do
#    Deployment + envFrom dos Secrets de DB (gerados pelas ExternalSecrets)
#    + volume com o ConfigMap do realm.
kc apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: keycloak-import-override
  namespace: uniplus
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: kc-import
          image: quay.io/keycloak/keycloak:26.6.1
          args:
            - import
            - --override=true
            - --file
            - /opt/keycloak/data/import/uniplus-realm.json
          envFrom:
            # DB credentials (KC_DB_USERNAME, KC_DB_PASSWORD) — Postgres no data-host.
            - secretRef: { name: keycloak-replica-uniplus-standalone-db }
            # client_secret do uniplus-portal — UNIPLUS_PORTAL_CLIENT_SECRET é
            # referenciado como ${VAR} no realm JSON. Sem este envFrom, o
            # `kc.sh import --override` substituiria o placeholder por string
            # vazia/literal, quebrando OIDC do client após restore.
            - secretRef: { name: keycloak-replica-uniplus-standalone-client-uniplus-portal }
          env:
            - { name: KC_DB, value: postgres }
            - { name: KC_DB_URL_HOST, value: 10.0.2.87 }
            - { name: KC_DB_URL_PORT, value: "5432" }
            - { name: KC_DB_URL_DATABASE, value: keycloak }
          volumeMounts:
            - { name: realm, mountPath: /opt/keycloak/data/import, readOnly: true }
      volumes:
        - name: realm
          configMap:
            name: keycloak-replica-uniplus-standalone-realm-uniplus
EOF

# 3) Aguardar conclusão e conferir logs
kc wait job -n uniplus keycloak-import-override \
  --for=condition=complete --timeout=300s
kc logs -n uniplus job/keycloak-import-override

# 4) Scale-up de volta (Job é GC-removido por ttlSecondsAfterFinished=300s)
kc scale deployment -n uniplus keycloak-replica-uniplus-standalone --replicas=1
```

### 10.6 Promover cert para Let's Encrypt prod

Standalone usa `letsencrypt-staging` durante a Fase 4–6 (90d, browser warning aceitável para validação). Após smoke test completo (Fase 6 — login real do portal), promover para certificado válido:

1. Em `environments/standalone/values.yaml`, alterar a key real consumida pelo chart:

   ```yaml
   keycloak:
     ingress:
       tls:
         certManager:
           clusterIssuer: letsencrypt-prod   # antes: letsencrypt-staging
   ```

2. Commit + PR. O ArgoCD reconcilia o Certificate; cert-manager renova o Secret apontado por `keycloak.ingress.tls.secretName` automaticamente (HTTP-01 via Traefik).
3. Confirmar no cluster:

   ```bash
   kc get certificate -n uniplus keycloak-replica-uniplus-standalone -o yaml \
     | grep -E "issuerRef|status:"
   # Esperado: issuerRef.name=letsencrypt-prod e status.conditions.Ready=True
   ```

### 10.7 Troubleshooting

| Sintoma | Diagnóstico | Fix |
|---|---|---|
| Pod em `CreateContainerConfigError: secret X not found` | ESO ainda não sincronizou | `kc describe externalsecret -n uniplus`; conferir Vault unsealed e `vault-default` Ready |
| Pod Running mas `curl /auth/...` retorna 404 | `KC_HTTP_RELATIVE_PATH=/auth` faltando ou `KC_HOSTNAME` sem `/auth` no final | Validar env vars no Pod; ajustar `keycloak.hostname.url` e `keycloak.http.relativePath` no values |
| Login redireciona pra HTTP em vez de HTTPS | `KC_PROXY_HEADERS=xforwarded` faltando ou `KC_HTTP_ENABLED=false` | Conferir env vars; Traefik deve passar `X-Forwarded-{Proto,Host,Port,Prefix}` (default em IngressRoute) |
| Realm import falha com `Could not parse JSON` | Erro de sintaxe no `uniplus-realm.json` ou `${VAR}` referenciando env var não setada | Validar JSON localmente (`jq . files/uniplus-realm.json`); conferir se todos os `UNIPLUS_PORTAL_*` env vars existem no Pod |
| Pod startupProbe falha após 10min | Postgres lento na 1ª conexão (cold start) ou DB inacessível | `kc logs ... --previous`; conferir `nc -zv 10.0.2.87 5432` do Pod (sem hostNetwork) |

---

*Documento mantido pelo CTIC/UNIFESSPA. Atualizações via Pull Request.*
