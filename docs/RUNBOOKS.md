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

> **Pré-requisito infra:** as VMs OCI E4.Flex (k8s-host + data-host), VCN, subnets, NSGs, Block Volumes e Reserved Public IP são provisionados via OpenTofu em `provisioning/oci/standalone/` — ver [`provisioning/oci/standalone/README.md`](../provisioning/oci/standalone/README.md) e issues [#52](https://github.com/unifesspa-edu-br/uniplus-infra/issues/52)–[#58](https://github.com/unifesspa-edu-br/uniplus-infra/issues/58). Os procedures abaixo assumem essas VMs já no ar com Ubuntu 24.04 LTS instalado.
>
> **Pré-requisito SSH:** chave SSH `~/.ssh/id_ed25519` com acesso a ambos os hosts como usuário `ubuntu`.

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

O cluster K3s recém-bootstrappeado precisa ser registrado no ArgoCD com **labels apropriados** para que o ApplicationSet em `argocd/applicationset.yaml` o detecte e inicie a sincronização. O ApplicationSet generaliza por label — sem alterações no manifest desde que os labels sejam consistentes.

**Pré-requisito:** ArgoCD operacional no cluster (validado pelo passo final de §8.1) e `argocd` CLI instalada na workstation do operador (`brew install argocd` ou pacote oficial).

**Passo 1 — Recuperar a senha inicial admin do ArgoCD.**

```bash
# Senha inicial é gerada pelo ArgoCD na primeira sincronização e fica no Secret
# argocd-initial-admin-secret. Após o primeiro login, **rotacionar imediatamente**
# via `argocd account update-password` e custodiar em Vault em
# secret/standalone/argocd/admin (RUNBOOKS §14.4 pattern).
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

**Passo 2 — Port-forward + login na workstation.**

```bash
# Terminal 1 — port-forward (manter aberto durante o registro)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n argocd port-forward svc/argocd-server 8080:443 &

# Terminal 2 — login + register
argocd login localhost:8080 --insecure --username admin --password <senha-passo-1>
```

**Passo 3 — Registrar o cluster com labels do ApplicationSet.**

O ApplicationSet em `argocd/applicationset.yaml` filtra clusters via dois labels: `uniplus.io/managed=true` (cluster gerenciado pela plataforma) e `environment=standalone` (overlay GitOps a aplicar). Sem ambos, o cluster fica visível mas não recebe Apps.

```bash
# Como o K3s é o cluster local onde o próprio ArgoCD roda, o registro é
# `--in-cluster` (sem necessidade de kubeconfig externo).
argocd cluster add default \
  --name uniplus-standalone \
  --in-cluster \
  --label uniplus.io/managed=true \
  --label environment=standalone
```

> **Por que dois labels?** `uniplus.io/managed` separa clusters da plataforma de eventuais clusters de teste/sandbox que partilhem o controle plane do ArgoCD. `environment=standalone` é o seletor do overlay GitOps — distingue do `lab-sp1`, `lab-sp2`, `lab-pa1`, `prod-sp1`, etc. ApplicationSet usa **interseção** dos labels: cluster precisa ter os dois.

**Passo 4 — Validar reconciliação.**

```bash
# Listar clusters registrados
argocd cluster list
# Esperado: uniplus-standalone com STATUS=Successful

# Ver Apps que o ApplicationSet criou para este cluster
argocd app list --selector environment=standalone
# Esperado: uma App por chart de apps/ e platform/, todos Synced/Healthy
# (alguns podem ficar OutOfSync inicialmente até o primeiro reconcile completar)
```

**Tempo estimado:** 2–5 minutos (port-forward + login + register + primeiro reconcile do ApplicationSet).

> **Custódia da senha admin pós-rotação:**
>
> ```bash
> # Após `argocd account update-password`, custodiar em Vault
> ARGOCD_NEW_PASSWORD="..." \
> VAULT_TOKEN=hvs.xxx \
>   vault kv put secret/standalone/argocd/admin password="$ARGOCD_NEW_PASSWORD"
> ```

### 8.3.1 DNS records — CNAMEs por host

A topologia standalone expõe 11 hostnames sob `standalone.portaluni.com.br` via Traefik IngressRoutes (validados pelo Cenário 13 do `VALIDATION-PLAN.md`). O FQDN raiz `standalone.portaluni.com.br` aponta para o **Reserved Public IP** OCI (provisionamento via `provisioning/oci/standalone/` — issue #56). Os demais são CNAMEs apontando para o FQDN raiz.

| Host | Tipo | Aponta para | Apps consumidoras |
|---|---|---|---|
| `standalone.portaluni.com.br` | A | Reserved Public IP OCI | keycloak-replica (subpath `/auth/*`), Grafana (`/grafana/*`) |
| `portal.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | uniplus-web (Angular SPA portal) |
| `selecao.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | uniplus-web (Angular SPA selecao) |
| `ingresso.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | uniplus-web (Angular SPA ingresso) |
| `api-portal.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | uniplus-api-portal (.NET) |
| `api-selecao.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | uniplus-api-selecao (.NET) |
| `api-ingresso.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | uniplus-api-ingresso (.NET) |
| `minio.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | MinIO Console (object storage admin UI, RUNBOOKS §12.6) |
| `kafka-ui.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | AKHQ (Kafka admin UI) |
| `schema-registry.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | Apicurio Schema Registry |
| `redis-ui.standalone.portaluni.com.br` | CNAME | `standalone.portaluni.com.br` | RedisInsight |

**Provisionar via OCI CLI** (alternativa ao Tofu — útil quando o caminho declarativo do `#56` ainda não está completo):

```bash
ZONE_OCID="ocid1.dns-zone.oc1..xxxxx"  # zona portaluni.com.br

# Reserved Public IP (já existente conforme #56) — aqui apenas referência:
RESERVED_IP=$(oci network public-ip get --public-ip-address-ocid \
  ocid1.publicip.oc1..xxxxx --query 'data."ip-address"' --raw-output)

# Hostnames CNAME apontando para standalone.portaluni.com.br
HOSTS=(portal selecao ingresso api-portal api-selecao api-ingresso minio kafka-ui schema-registry redis-ui)

for host in "${HOSTS[@]}"; do
  oci dns record rrset update \
    --zone-name-or-id "$ZONE_OCID" \
    --domain "$host.standalone.portaluni.com.br" \
    --rtype CNAME \
    --items '[{"domain":"'"$host.standalone.portaluni.com.br"'","rdata":"standalone.portaluni.com.br.","rtype":"CNAME","ttl":300}]' \
    --force
  echo "Criado/atualizado: $host.standalone.portaluni.com.br → standalone.portaluni.com.br"
done
```

**Validar propagação** (TTL 300 = ≤ 5 min em primeira criação):

```bash
for host in standalone portal.standalone selecao.standalone ingresso.standalone \
            api-portal.standalone api-selecao.standalone api-ingresso.standalone \
            minio.standalone kafka-ui.standalone schema-registry.standalone redis-ui.standalone; do
  echo -n "$host.portaluni.com.br → "
  dig +short "$host.portaluni.com.br" | tail -1
done
# Todos devem resolver para o IP do Reserved Public IP.
```

**Trigger de reavaliação:** quando `provisioning/oci/standalone/dns.tf` (sub-task de #56) entregar o caminho declarativo, este procedimento OCI CLI vira fallback de emergência apenas. Tofu fica como fonte canônica.

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

### 8.8 Troubleshooting do bootstrap

Sintomas comuns durante a primeira ativação do ambiente standalone, com diagnóstico e remediação.

| Sintoma | Causa provável | Resolução |
|---|---|---|
| `kubectl get nodes` retorna `NotReady` após §8.1 | K3s ainda inicializando (containerd, CNI, kubelet); ou conflito de CIDR com VCN | Aguardar 1–2 min e reexecutar. Se persistir: `journalctl -u k3s --since "5 min ago" -p err`. CIDR conflict aparece com `iptables: rule does not match`; ajustar `--cluster-cidr`/`--service-cidr` no service unit do K3s. |
| `kubectl -n vault exec ... -- vault status` retorna `Sealed=true` após restart | Pod do Vault foi reiniciado (manutenção, OOM, upgrade K3s) — Shamir exige unseal manual a cada start | Executar §8.4.2 com 3 das 5 unseal keys custodiadas no gestor institucional. **Não é one-shot — é procedimento operacional recorrente em standalone enquanto Vault rodar com Shamir** (ver decisão temporária na introdução de §8.4). |
| `argocd app list` mostra todas as apps em `OutOfSync` ou `Unknown` após §8.3 | ApplicationSet não detectou o cluster; labels ausentes ou cluster não registrado | Validar `argocd cluster list` mostra `uniplus-standalone` com `STATUS=Successful`. Se ausente: re-executar §8.3 garantindo as 2 flags `--label uniplus.io/managed=true --label environment=standalone`. Sem **ambos** os labels o ApplicationSet ignora o cluster (intersecção de seletores em `argocd/applicationset.yaml`). |
| Apps do ApplicationSet ficam em `Healthy=Unknown` por > 5 min | Reconciliação lenta do primeiro deploy (download de imagens grandes); ou Helm dep fail no chart | `argocd app sync <app>` para forçar; ver eventos com `argocd app get <app>`. Se `helm-template`: `argocd app history <app>` mostra última tentativa de manifest gen + erros. |
| Pods em `CreateContainerConfigError: secret X not found` em todos os apps | ESO não sintetizou Secret porque Vault está selado ou ClusterSecretStore não está Ready | 1) `vault status` (selado? rodar §8.4.2). 2) `kc get clustersecretstore vault-default -o yaml \| grep -A5 status` — ver se `Valid` e `Ready`. 3) Se ESO ok mas Vault sem o secret esperado: custódia foi pulada (cada componente tem sua subseção §10.x/§14.1/§15.6 para popular). |
| `cert-manager` não emite certs — Pods Certificate em `False`, log `dns01: connection refused` | DNS-01 challenge bloqueado por NSG ou DNS zone não delegada | Validar resolver upstream do data-host (`/etc/resolv.conf`); ACME-01 challenge via HTTP-01 funciona como fallback enquanto LE staging valida o setup (ver §10.6 troubleshooting cert-manager). |
| `oci dns record rrset update` retorna 404 zone-not-found | Zone OCID errado ou compartment scope insuficiente | `oci dns zone list --compartment-id <root> --query 'data[?name==`portaluni.com.br`]'` — copiar `id` correto. Se vazio: zona ainda não criada na OCI DNS (`provisioning/oci/standalone/dns.tf` em #56). Workaround manual via OCI Console > DNS > Public Zones. |
| `argocd cluster add` falha com `permission denied` | Token admin do ArgoCD expirou | `argocd account get-user-info` — se 401, re-autenticar via §8.3 passo 2. Se persiste: senha admin pós-rotação não foi custodiada em Vault e foi perdida — workaround: `kubectl -n argocd patch secret argocd-secret --type=merge -p '{"stringData":{"admin.password":"<bcrypt>"}}'` (ver argocd-cm anotações). |

**Logs estruturados de bootstrap** (úteis para post-mortem):

```bash
# K3s service journal (últimos 30 min)
sudo journalctl -u k3s --since "30 min ago" --no-pager

# ArgoCD controller (sync events)
kubectl -n argocd logs deploy/argocd-application-controller --tail=200

# ESO operator (ClusterSecretStore Valid checks)
kubectl -n external-secrets-system logs deploy/external-secrets --tail=100
```

## 9. Data services no data-host (standalone)

Em standalone, os componentes stateful rodam **fora do K8s** — containers Docker gerenciados por `systemd` no data-host. A primeira entrega da Epic `data/*` codifica o Postgres 18; Kafka, MinIO e Redis seguirão o mesmo padrão.

### 9.1 Postgres 18 — bootstrap automatizado

A função `step_data_setup_postgres` em `scripts/bootstrap-standalone.sh` provisiona, na ordem:

1. Diretórios `/var/lib/uniplus/postgres/{data,init}` com ownership `70:70` (uid `postgres` no container `postgres:18-alpine` — Alpine usa uid 70, distinto do uid 999 das imagens Debian-based).
2. `.bootstrap-creds` (root:root 600) em `/var/lib/uniplus/postgres/.bootstrap-creds` com `super_pw` + `keycloak_pw` (256 bits cada via `openssl rand -hex 32`) — gerado **somente na primeira execução**.
3. Init SQL **efêmero** `/var/lib/uniplus/postgres/init/00-keycloak.sql` (mode `600`, owner `70:70`) — gerado APENAS quando o cluster ainda não foi inicializado (sem `PG_VERSION` em `data/`). Cria role `keycloak` + database `keycloak` na primeira inicialização. Após `pg_isready` confirmar que o entrypoint executou o script, o arquivo é shredded (`shred -u`) — `keycloak_pw` em cleartext NÃO persiste no filesystem do data-host entre runs (snapshots/backups da LVM `vg-postgres` não capturam cópia extra do secret).
4. **Credential file** `/etc/credstore/uniplus-postgres-password` (root:root `400`, dir `700`) contendo `super_pw` em texto puro (sem trailing newline). Issue #128 — substitui o legacy `/etc/uniplus-postgres.env` (EnvironmentFile) pelo pattern `LoadCredential=` do systemd 250+: a senha é bind-mounted pelo systemd em `${CREDENTIALS_DIRECTORY}/postgres-password` (tmpfs do unit, isolada de `/proc/<pid>/environ`) e nunca trafega via env do processo. Em Ubuntu 24.04 LTS (systemd 255), o file pode ser opcionalmente cifrado via `systemd-creds encrypt --name=postgres-password --tpm2-pcrs=...` para binding ao TPM2 do host (ver §9.6).
5. `systemd` unit `/etc/systemd/system/uniplus-postgres.service` com `Restart=always`, `Type=simple`, `LoadCredential=postgres-password:/etc/credstore/uniplus-postgres-password`, container em `--network host` (Postgres listen em `10.0.2.87:5432`). O `docker run` consome a senha via `POSTGRES_PASSWORD_FILE=/run/secrets/postgres-password` (suportado nativamente pelo entrypoint `postgres:18-alpine`) — bind-mount read-only de `${CREDENTIALS_DIRECTORY}/postgres-password` no container, lido pelo entrypoint **antes** do `gosu` drop para uid 70.

**Idempotência (decisões independentes):**

- `.bootstrap-creds`: se já existe, preserva; se não existe e cluster já inicializado, aborta apontando §9.4; senão, gera novas senhas.
- Init SQL: regenerado sempre que o cluster ainda não tem `PG_VERSION` (cobre o fluxo §9.4 — restore creds, data dir vazio → SQL recriado a partir do `keycloak_pw` persistido). Cleanup defensivo se leftover persiste após cluster já estar inicializado.
- Credential file (`/etc/credstore/uniplus-postgres-password`) + systemd unit: sempre re-escritos a partir do `super_pw` em `.bootstrap-creds` — corrige drift sem afetar state do cluster. Legacy `/etc/uniplus-postgres.env` (EnvironmentFile) é shredded via `shred -u` na primeira execução pós-migração.
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

### 9.6 Rotação de credentials e TPM2 binding (issue #128)

A migração de `EnvironmentFile=` para `LoadCredential=` (PR fecha #128) muda o pattern de secret delivery do Postgres systemd. Este sub-runbook cobre operações Day-2 sobre `/etc/credstore/uniplus-postgres-password`.

**Quando rotacionar:**

- Credential exposta acidentalmente (compartilhada em chat/PR/issue por engano)
- Custódia transferida (engenheiro DevOps off-boarded)
- Janela de manutenção planejada com bump conjunto de senhas

**Pré-requisitos:** acesso root no data-host (`10.0.2.87`); cliente Keycloak parado ou em janela onde reconnect é aceitável (Postgres restart força re-auth de connections existentes).

> ⚠️ **Procedimento assume senha hex-only** (`openssl rand -hex N` — caracteres `[0-9a-f]`). Se a política institucional exigir charset diferente (símbolos, mistura), o `ALTER USER ... WITH PASSWORD '$NEW_PW'` em heredoc unquoted e o `sed -i "s/.../...$NEW_PW/"` ficam vulneráveis a escape (`'`, `/`, `&`, etc.). Para outros charsets, gerar via `openssl rand -base64 N | tr -d '/=+'` e validar manualmente, ou refatorar para passar via `psql -v` com `quote_literal()`.
>
> Hex é suficientemente forte (32 bytes hex = 128 bits de entropia) e mantém o procedimento simples — recomendamos manter.

**Passo 1 — Gerar nova senha:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
NEW_PW=$(openssl rand -hex 32)
echo "New super_pw (custodiar antes de continuar): $NEW_PW"
```

**Passo 2 — Atualizar a senha no cluster Postgres em si (`ALTER USER`):**

```bash
sudo docker exec -i uniplus-postgres psql -U postgres -d postgres <<SQL
ALTER USER postgres WITH PASSWORD '$NEW_PW';
SQL
unset NEW_PW   # <-- só desfazer DEPOIS de também atualizar o credential file
```

> ⚠️ Se desfazer `NEW_PW` antes do Passo 3, ficamos com cluster aceitando a nova senha mas systemd ainda servindo a antiga via LoadCredential — próximo restart do unit falha em `pg_isready`. Sequência rígida.

**Passo 3 — Atualizar credential file e `.bootstrap-creds`:**

```bash
# Reescrever o credential file (mode 400 root:root, sem trailing newline)
printf '%s' "$NEW_PW" | sudo tee /etc/credstore/uniplus-postgres-password >/dev/null
sudo chmod 400 /etc/credstore/uniplus-postgres-password

# Atualizar .bootstrap-creds para que re-runs do bootstrap reflitam a senha viva
sudo sed -i "s/^super_pw=.*/super_pw=$NEW_PW/" /var/lib/uniplus/postgres/.bootstrap-creds
unset NEW_PW
```

**Passo 4 — Re-iniciar o unit (zero downtime se Keycloak tolera reconnect):**

```bash
sudo systemctl restart uniplus-postgres
sudo docker exec uniplus-postgres pg_isready -U postgres   # esperado: accepting connections
```

**Passo 5 — Validar conectividade end-to-end** (do k8s-host, conforme §9.3).

> O `keycloak_pw` (senha do role `keycloak`, não `postgres`) é independente — fica no Vault em `secret/standalone/postgres/keycloak`. Rotação dele segue procedimento separado (`ALTER USER keycloak` + atualizar Vault + restart Keycloak Pod para re-pull do ExternalSecret).

#### 9.6.1 TPM2 binding (opcional)

Em Ubuntu 24.04 (systemd 255), o credential file pode ser cifrado e bound ao TPM2 do host — descriptografar fora desta máquina específica fica computacionalmente inviável.

**Verificar enrollment:**

```bash
# 1) TPM2 disponível e systemd-creds vê
sudo systemd-creds has-tpm2
# Esperado: yes

# 2) Imprime PCRs disponíveis para escolha de bind
sudo tpm2_pcrread sha256
```

**Escolha de PCR para o bind:**

| PCR | Cobertura | Estabilidade em servidor Ubuntu |
|---|---|---|
| 0 | BIOS/UEFI code | estável entre boots; muda em firmware update |
| 4 | Boot loader code | muda em update do GRUB/shim |
| 7 | Secure Boot policy | em servidor sem Secure Boot habilitado, valor é constante (zeros) — válido para sealing mas não adiciona binding real |
| 11 | Unified Kernel Image (UKI) | só preenchido com UKI (Ubuntu 24.04 default ainda usa initrd tradicional — PCR 11 fica zero) |

Recomendação para Ubuntu 24.04 server **sem UKI** (default): usar **PCR 0** (binding ao firmware da máquina). Adicionar PCR 7 só se Secure Boot estiver habilitado e enrollment do MOK customizado importar para a equação. PCRs 4 e 11 só fazem sentido com configurações específicas.

**Cifrar o credential com TPM2 binding:**

```bash
# Read+encrypt+write atomicamente. --pretty emite o blob em base64 multiline
# para inspeção; pode-se trocar por --binary se preferir.
NEW_PW_BLOB=$(sudo systemd-creds encrypt \
    --name=postgres-password \
    --tpm2-pcrs=0 \
    /etc/credstore/uniplus-postgres-password -)

# Sobrescrever in-place com o blob cifrado
echo "$NEW_PW_BLOB" | sudo tee /etc/credstore/uniplus-postgres-password >/dev/null
sudo chmod 400 /etc/credstore/uniplus-postgres-password
unset NEW_PW_BLOB
```

Após o encrypt, mudar a syntax na unit:

```ini
# /etc/systemd/system/uniplus-postgres.service
LoadCredentialEncrypted=postgres-password:/etc/credstore/uniplus-postgres-password
```

(O bootstrap não força encrypt automaticamente — decisão deliberada para permitir validação antes de tornar o binding obrigatório.)

`systemctl restart uniplus-postgres` e `pg_isready` para confirmar. Se PCRs mudarem (firmware update, kernel diferente em boot via grub), o decrypt falha; ver `man systemd-creds` para policies de unsealing avulso.

> ⚠️ TPM2 binding **destrói portabilidade** do credential. Se o data-host for re-provisionado ou o TPM resetar, o blob fica inrecuperável. Sempre manter custódia paralela do `super_pw` em texto puro no gestor institucional, separadamente.

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

# Bootstrap admin — gera senha aleatória (32 bytes hex), persiste e custodia
ADMIN_PW=$(openssl rand -hex 32)
vault kv put secret/standalone/keycloak/admin \
  username=admin password="$ADMIN_PW"
echo "Admin password (salvar no gestor institucional): $ADMIN_PW"

# trap EXIT cuida de kill + unset ao sair do shell
```

> ⚠️ **Custódia:** salvar `ADMIN_PW` em gestor institucional (Bitwarden, 1Password, Vault corporativo). Standalone não é cofre durável — re-bootstrap via Tofu pode regenerar Shamir keys e perder este secret.
>
> O client `uniplus-portal` é **public client** (SPA Angular + Authorization Code + PKCE) — não há `client_secret` para custodiar. PKCE substitui o secret em fluxos de browser; o `code_verifier` gerado pelo SPA garante que apenas o cliente que iniciou a authorization request consegue trocar o code por tokens.

### 10.2 Verificar pod e ESO

```bash
kc() { sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }

# 1) ExternalSecrets sintetizaram os Secrets K8s
kc get externalsecret -n uniplus
# Esperado: 2 ESOs com STATUS=SecretSynced READY=True
#   - keycloak-replica-uniplus-standalone-db
#   - keycloak-replica-uniplus-standalone-bootstrap-admin

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

### 10.4 Rotacionar admin password (master realm)

`uniplus-portal` é public client com PKCE — não tem secret pra rotacionar. Para o admin do master realm (única credencial Keycloak custodiada em Vault):

```bash
# 1) Gerar novo password e atualizar Vault
NEW_ADMIN_PW=$(openssl rand -hex 32)
vault kv put secret/standalone/keycloak/admin \
  username=admin password="$NEW_ADMIN_PW"

# 2) Forçar refresh imediato do ExternalSecret (sem esperar refreshInterval=1h)
kc annotate externalsecret -n uniplus \
  keycloak-replica-uniplus-standalone-bootstrap-admin \
  force-sync="$(date +%s)" --overwrite

# 3) Aplicar no Keycloak via kcadm.sh — usa o admin antigo (que ainda está
#    no env do pod via envFrom) pra autenticar e setar a nova senha. NEW_ADMIN_PW
#    vai via stdin (here-string + read -r), nunca em argv.
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  read -r NEW_PW
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD"
  /opt/keycloak/bin/kcadm.sh set-password -r master \
    --username "$KC_BOOTSTRAP_ADMIN_USERNAME" --new-password "$NEW_PW"
' <<<"$NEW_ADMIN_PW"
unset NEW_ADMIN_PW

# 4) Restart do Pod para que o env KC_BOOTSTRAP_ADMIN_PASSWORD reflita o
#    novo valor (envFrom já trocou via ESO, mas o env do processo é
#    capturado no startup — restart é necessário para próximas operações
#    de kcadm.sh dentro do pod usarem a senha nova).
kc rollout restart deployment -n uniplus keycloak-replica-uniplus-standalone
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
          image: ghcr.io/unifesspa-edu-br/uniplus-keycloak:26.6.1-0
          args:
            - import
            - --override=true
            - --file
            - /opt/keycloak/data/import/uniplus-realm.json
          envFrom:
            # DB credentials (KC_DB_USERNAME, KC_DB_PASSWORD) — Postgres no data-host.
            # Único Secret necessário para offline import: o realm JSON foi
            # renderizado pelo Helm no ConfigMap (clientId/rootUrl/redirectUris
            # via tpl) e o uniplus-portal é public client (sem secret).
            - secretRef: { name: keycloak-replica-uniplus-standalone-db }
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

## 11. Redis (standalone)

Cache local — `redis:8.6.3-alpine` em container Docker gerenciado por systemd no data-host (`10.0.2.87:6379`). Pré-requisito: §9 Postgres systemd ativo (mesmo data-host) + Vault unsealed para custódia da senha.

### 11.1 Redis 8.6.3 — bootstrap automatizado

A função `step_data_setup_redis` em `scripts/bootstrap-standalone.sh` provisiona, na ordem:

1. Diretórios `/var/lib/uniplus/redis/data` (mode `750`, owner `999:1000` — uid `redis` no container `redis:8.6.3-alpine`) e `/etc/uniplus-redis/` (mode `755`, owner `root:root` — traversável pelo uid 999 do container; confidencialidade dos arquivos é via mode dos próprios files).
2. `.bootstrap-creds` (root:root 600) em `/var/lib/uniplus/redis/.bootstrap-creds` com `default_pw` (256 bits via `openssl rand -hex 32`) — gerado **somente na primeira execução**.
3. ACL file `/etc/uniplus-redis/users.acl` (mode `600`, owner `999:1000`) — sempre regerado a partir de `default_pw` lido do `.bootstrap-creds`. Conteúdo: `user default on >$pw ~* &* +@all`.
4. Config `/etc/uniplus-redis/redis.conf` (mode `644`, owner `root:root` — sem segredos, conf é legível para auditoria) com `bind 10.0.2.87 127.0.0.1 -::1`, `protected-mode yes`, `aclfile /usr/local/etc/redis/users.acl`, AOF (`appendfsync everysec`) + RDB (`save 3600 1 300 100 60 10000`), `maxmemory 2gb` `allkeys-lru`.
5. `systemd` unit `/etc/systemd/system/uniplus-redis.service` com `Restart=always`, container em `--network host` (Redis listen em `10.0.2.87:6379`), config dir mounted **read-only** (`-v /etc/uniplus-redis:/usr/local/etc/redis:ro`).

**Diferença vs Postgres (§9.1):** o ACL file **persiste** entre runs (redis-server lê em todo startup), enquanto o init SQL do Postgres é efêmero (executado uma vez pelo entrypoint, depois shredded). O ACL contém o cleartext da senha — proteção é via mode `600` + owner uid do container; visibilidade limitada a quem tem `sudo` no data-host. `ACL SAVE` / `CONFIG REWRITE` no container são noop por o mount ser read-only — fonte da verdade da senha continua sendo `.bootstrap-creds` + Vault.

**Idempotência:**

- `.bootstrap-creds`: preserva se existe; gera se ausente; aborta se ACL file já existe sem `.bootstrap-creds` (regenerar produziria mismatch entre ACL ativo e Vault — apps autenticando via Vault falhariam).
- ACL file + redis.conf: sempre re-aplicados (cheap; redis-server faz reload na próxima inicialização).
- systemd unit: sempre re-aplicado.
- Serviço já ativo: bootstrap não reinicia (evita downtime).

**Verificação imediata pós-bootstrap (no data-host):**

```bash
sudo systemctl status uniplus-redis
sudo docker exec -i uniplus-redis sh -c 'read -r P; REDISCLI_AUTH="$P" redis-cli ping' \
  <<<"$(sudo grep ^default_pw= /var/lib/uniplus/redis/.bootstrap-creds | cut -d= -f2)"
# Esperado: PONG
sudo docker exec -i uniplus-redis sh -c \
  'read -r P; REDISCLI_AUTH="$P" redis-cli info persistence' \
  <<<"$(sudo grep ^default_pw= /var/lib/uniplus/redis/.bootstrap-creds | cut -d= -f2)" \
  | grep -E '^(aof_enabled|rdb_last_save_time):'
# Esperado: aof_enabled:1
```

### 11.2 Custódia da senha inicial

> ⚠️ **CRÍTICO.** O `.bootstrap-creds` é o **único rastro fora do ACL file** da senha gerada. Custodiar imediatamente em gestor institucional + Vault standalone, depois `shred -u` o arquivo.

**Passo 1 — Ler senha no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo cat /var/lib/uniplus/redis/.bootstrap-creds
# default_pw=<64 hex>
```

**Passo 2 — Salvar `default_pw` no Vault standalone (executar do k8s-host):**

> Mesmo padrão de higiene da §9.2 (port-forward + token via env do shell, não argv).

```bash
read -rsp "Cole default_pw (do passo 1): " RED_PW; echo

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset RED_PW VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

vault kv put secret/standalone/redis/default \
  host=10.0.2.87 \
  port=6379 \
  username=default \
  password="$RED_PW"

vault kv get secret/standalone/redis/default
# Esperado: campos host/port/username/password presentes
```

**Passo 3 — Limpar `.bootstrap-creds` no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo shred -u /var/lib/uniplus/redis/.bootstrap-creds
```

> ⚠️ Após `shred -u`, re-execução do bootstrap **abortaria** com mensagem apontando §11.4 (ACL file persiste, mas não há mais como regenerá-lo sem fonte da senha). Restaurar `.bootstrap-creds` a partir do Vault antes de re-executar.

### 11.3 Validação end-to-end (pod K8s → Redis)

Confirma que pods do cluster K3s alcançam o Redis no data-host via TCP. Pré-requisito: PR #125 aplicado (iptables FORWARD ACCEPT entre flannel CIDR e VCN).

**Executar no k8s-host:**

```bash
# 1) Conectividade TCP bruta
nc -zv 10.0.2.87 6379
# Esperado: succeeded

# 2) Ler senha — fail fast se não disponível
REDIS_PW=$(ssh ubuntu@10.0.2.87 \
  "sudo grep default_pw= /var/lib/uniplus/redis/.bootstrap-creds 2>/dev/null | cut -d= -f2")
if [ -z "$REDIS_PW" ]; then
  echo "ERRO: default_pw não encontrado em .bootstrap-creds no data-host." >&2
  echo "  - Se .bootstrap-creds foi shredded (§11.2), restaure via §11.4 antes" >&2
  echo "    OU cole a senha manualmente: read -rsp 'default_pw: ' REDIS_PW; echo" >&2
  return 1 2>/dev/null || exit 1
fi

# 3) Pod ad-hoc com redis-cli (sem hostNetwork — usa flannel).
#    Senha via stdin → REDISCLI_AUTH (mesmo padrão §9.3 com PGPASSWORD)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml run redis-validation \
  --image=redis:8.6.3-alpine --restart=Never --rm -i --command -- \
  sh -c 'read -r PW; REDISCLI_AUTH="$PW" redis-cli -h 10.0.2.87 ping' \
  <<<"$REDIS_PW"
# Esperado: PONG
unset REDIS_PW
```

Se o pod fica preso em `Pending` ou retorna `Connection refused`: revisar §8.6/§8.7 do plano-pai (#123) e confirmar que `iptables -L FORWARD` no k8s-host mostra os ACCEPTs flannel↔VCN antes do `REJECT --reject-with icmp-host-prohibited`.

### 11.4 Restore: re-criar `.bootstrap-creds` a partir do Vault

Caso o operador tenha rodado `shred -u` (§11.2) e precise re-executar o bootstrap (ou recuperar a senha localmente para troubleshooting), recriar o arquivo a partir do Vault:

```bash
# No k8s-host — port-forward + leitura do secret (mesmo pattern §9.4)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset RED_PW VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

RED_PW=$(vault kv get -field=password secret/standalone/redis/default)

# Transmitir para o data-host via stdin do ssh — não cruza argv
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87 \
  "sudo tee /var/lib/uniplus/redis/.bootstrap-creds > /dev/null && \
   sudo chmod 600 /var/lib/uniplus/redis/.bootstrap-creds && \
   sudo chown root:root /var/lib/uniplus/redis/.bootstrap-creds" <<EOF
default_pw=$RED_PW
EOF
```

**Após reconstituir `.bootstrap-creds`:** rodar `./scripts/bootstrap-standalone.sh --role=standalone-data` no data-host. O bootstrap regenera o ACL file a partir do `default_pw` recém-restaurado e re-aplica config/unit. Se o serviço estava ativo, não reinicia — o ACL novo só passa a valer no próximo restart manual (`sudo systemctl restart uniplus-redis`) ou após `redis-cli ACL LOAD` via container.

### 11.5 Rotacionar `default_pw`

```bash
# 1) Gerar nova senha + atualizar Vault (k8s-host)
NEW_PW=$(openssl rand -hex 32)
vault kv put secret/standalone/redis/default \
  host=10.0.2.87 port=6379 username=default password="$NEW_PW"

# 2) Reconstituir .bootstrap-creds via §11.4 com o NEW_PW

# 3) Re-rodar bootstrap (regenera ACL file)
ssh ubuntu@10.0.2.87 "cd ~/uniplus-infra && ./scripts/bootstrap-standalone.sh --role=standalone-data"

# 4) Aplicar a nova ACL no Redis em runtime (sem restart):
ssh ubuntu@10.0.2.87 "sudo docker exec -i uniplus-redis sh -c \
  'read -r P; REDISCLI_AUTH=\"\$P\" redis-cli ACL LOAD' \
  <<<\"\$(sudo grep ^default_pw= /var/lib/uniplus/redis/.bootstrap-creds | cut -d= -f2)\""
# Esperado: OK

unset NEW_PW
```

> ⚠️ Apps consumidoras (Fase 5) que cacheiem a senha em ConfigMap/env precisam restart após rotação — o ESO refresh é assíncrono (default `refreshInterval=1h`); forçar via `kc annotate externalsecret ... force-sync="$(date +%s)" --overwrite`.

### 11.6 Backup e Restore

> Procedimento detalhado em sub-task da Story #118 (paralelo aos backups Postgres). Resumo:
>
> - **Backup:** AOF rewrite + cópia do `appendonlydir/` para bucket MinIO (`s3://backups/redis/<timestamp>/`) via systemd timer no data-host.
> - **Restore:** parar `uniplus-redis`, restaurar `appendonlydir/` em `$DATA_BASE/redis/data/`, ajustar ownership `999:1000`, iniciar serviço.
>
> Em standalone, perda de Redis é **aceitável** — cache, não fonte da verdade. Aplicações reconstroem state a partir do Postgres no próximo cold path.

### 11.7 Troubleshooting

| Sintoma | Diagnóstico | Fix |
|---|---|---|
| `WRONGPASS invalid username-password` no log do app | Senha no app desatualizada vs Vault, ou ACL file e Vault desincronizados | Conferir `vault kv get secret/standalone/redis/default` vs `default_pw` em `.bootstrap-creds`; se mismatch, executar §11.5 |
| Container reinicia em loop com `Configuration loading: ACL file not readable` | Ownership do `users.acl` ≠ `999:1000` ou mode ≠ `600` (uid 999 do container precisa ser owner) | `sudo chown 999:1000 /etc/uniplus-redis/users.acl && sudo chmod 600 /etc/uniplus-redis/users.acl` |
| `DENIED Redis is running in protected mode` | `bind` ausente em `redis.conf` ou ACL file vazio | Validar `redis.conf` mounted contém `bind` + `aclfile`; re-executar bootstrap |
| `nc -zv 10.0.2.87 6379` succeeded mas `redis-cli` retorna `Could not connect to Redis: Connection reset` | iptables FORWARD ainda dropando flannel→VCN ou app pod usa IP errado | `kc exec` no pod e testar `nc -zv 10.0.2.87 6379` direto; conferir resultado do bloco §11.3 |
| AOF cresce indefinidamente | `auto-aof-rewrite-percentage 100` não dispara (default mas pode ter sido desligado em config customizada) | `redis-cli BGREWRITEAOF`; revisar `redis.conf` |
| OOM kills do container | `maxmemory 2gb` excedido ou cgroup limit do host menor | `redis-cli INFO memory`; ajustar `maxmemory` em `redis.conf` ou liberar memória no host |

## 12. MinIO (standalone)

Object storage AGPL community release `RELEASE.2025-09-07T16-13-09Z` — container Docker gerenciado por systemd no data-host (`10.0.2.87:9000` API + `:9001` Console). Single-node single-drive (SNSD), única topologia suportada em standalone single-host. Pré-requisito: §9 Postgres + §11 Redis ativos no data-host (mesmo padrão systemd).

> ⚠️ **Aviso community vs enterprise:** este é o **último release AGPL** antes do split MinIO/AIStor (2025-09). Security fixes pós-Setembro/2025 só estão disponíveis em AIStor enterprise. Aceitável em standalone (validação) mas decisão arquitetural pra hml/prod precisa avaliar alternativas (Garage, SeaweedFS, build próprio do source) — backlog Story futura.

### 12.1 MinIO 2025-09 — bootstrap automatizado

A função `step_data_setup_minio` em `scripts/bootstrap-standalone.sh` provisiona, na ordem:

1. Diretório `/var/lib/uniplus/minio/data` (mode `750`, owner `1000:1000` — uid `minio` criado dinamicamente pelo entrypoint via `chroot --userspec`).
2. `.bootstrap-creds` (root:root 600) em `/var/lib/uniplus/minio/.bootstrap-creds` com `root_user` (16 bytes hex via `openssl rand -hex 16`) + `root_pw` (32 bytes hex via `openssl rand -hex 32`) — gerado **somente na primeira execução**. **Username NÃO é literal `admin`/`minioadmin`** — randomização reduz tentativas de chute.
3. EnvironmentFile `/etc/uniplus-minio.env` (root:root 600) com `MINIO_ROOT_USER`, `MINIO_ROOT_PASSWORD` (lidos do `.bootstrap-creds`), `MINIO_USERNAME=minio`, `MINIO_GROUPNAME=minio`, `MINIO_UID=1000`, `MINIO_GID=1000` (instruções para o entrypoint criar o user e fazer chroot).
4. `systemd` unit `/etc/systemd/system/uniplus-minio.service` com `Restart=always`, container em `--network host`, server `--address 10.0.2.87:9000 --console-address 10.0.2.87:9001`, data dir `/data` mounted via volume.
5. `step_data_bootstrap_minio_buckets` cria 4 buckets baseline idempotentemente via `mc mb --ignore-existing` em job one-shot (`quay.io/minio/mc:latest`):
   - `keycloak-backups` — destino de pg_dump
   - `loki-chunks` — chunks de log (observability)
   - `tempo-traces` — traces (idem)
   - `app-uploads` — bucket genérico para apps Uni+ (Fase 5)

**Idempotência:**

- `.bootstrap-creds`: preserva se existe; gera se ausente; aborta se `data/.minio.sys/` já formatado sem `.bootstrap-creds` (regenerar produziria mismatch entre MinIO runtime e Vault).
- EnvironmentFile + systemd unit: sempre re-aplicados.
- Buckets: `mc mb --ignore-existing` skip se já criados.
- Serviço já ativo: bootstrap não reinicia (evita downtime).

**Verificação imediata pós-bootstrap (no data-host):**

```bash
sudo systemctl status uniplus-minio
curl -sf http://10.0.2.87:9000/minio/health/live -o /dev/null -w "%{http_code}\n"
# Esperado: 200

# Listar buckets via mc one-shot (lê creds do .bootstrap-creds via stdin)
sudo docker run --rm -i --network host --entrypoint sh \
  quay.io/minio/mc:latest -c '
    read -r U; read -r P
    mc --quiet alias set local http://10.0.2.87:9000 "$U" "$P"
    mc ls local
  ' <<EOF
$(sudo grep ^root_user= /var/lib/uniplus/minio/.bootstrap-creds | cut -d= -f2)
$(sudo grep ^root_pw= /var/lib/uniplus/minio/.bootstrap-creds | cut -d= -f2)
EOF
# Esperado: 4 buckets (app-uploads/, keycloak-backups/, loki-chunks/, tempo-traces/)
```

### 12.2 Custódia das credenciais iniciais

> ⚠️ **CRÍTICO.** O `.bootstrap-creds` é o único rastro em disco do `root_user` + `root_pw`. Custodiar imediatamente em gestor institucional + Vault standalone, depois `shred -u`.

**Passo 1 — Ler credenciais no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo cat /var/lib/uniplus/minio/.bootstrap-creds
# root_user=<32 hex>
# root_pw=<64 hex>
```

**Passo 2 — Salvar no Vault standalone (executar do k8s-host):**

> Mesmo padrão de higiene das §9.2/§11.2 (port-forward + token via env, nunca argv).

```bash
read -rsp "Cole root_user (do passo 1): " MIN_USER; echo
read -rsp "Cole root_pw (do passo 1): " MIN_PW; echo

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset MIN_USER MIN_PW VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

vault kv put secret/standalone/minio/root \
  endpoint=http://10.0.2.87:9000 \
  region=us-east-1 \
  username="$MIN_USER" \
  password="$MIN_PW"

vault kv get secret/standalone/minio/root
# Esperado: campos endpoint/region/username/password presentes
```

**Passo 3 — Limpar `.bootstrap-creds` no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo shred -u /var/lib/uniplus/minio/.bootstrap-creds
```

> ⚠️ Após `shred -u`, re-execução do bootstrap **abortaria** com mensagem apontando §12.4 (data dir já formatado, sem fonte da senha em disco). Restaurar `.bootstrap-creds` a partir do Vault antes.

### 12.3 Validação end-to-end (pod K8s → MinIO)

Confirma que pods do cluster K3s alcançam MinIO no data-host via flannel→VCN. Pré-requisito: PR #125 aplicado (iptables FORWARD ACCEPT entre flannel CIDR e VCN).

**Executar no k8s-host:**

```bash
# 1) Conectividade TCP bruta (host → data-host)
nc -zv 10.0.2.87 9000   # API
nc -zv 10.0.2.87 9001   # Console
# Esperado: succeeded em ambas

# 2) Ler credenciais — fail fast se não disponíveis
MIN_USER=$(ssh ubuntu@10.0.2.87 \
  "sudo grep ^root_user= /var/lib/uniplus/minio/.bootstrap-creds 2>/dev/null | cut -d= -f2")
MIN_PW=$(ssh ubuntu@10.0.2.87 \
  "sudo grep ^root_pw= /var/lib/uniplus/minio/.bootstrap-creds 2>/dev/null | cut -d= -f2")
if [ -z "$MIN_USER" ] || [ -z "$MIN_PW" ]; then
  echo "ERRO: creds não encontradas. Se shredded (§12.2), restaure via §12.4." >&2
  return 1 2>/dev/null || exit 1
fi

# 3) Pod ad-hoc com mc (sem hostNetwork — usa flannel)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml run minio-validation \
  --image=quay.io/minio/mc:latest --restart=Never --rm -i --command -- \
  sh -c '
    read -r U; read -r P
    mc --quiet alias set s http://10.0.2.87:9000 "$U" "$P"
    mc ls s
  ' <<EOF
$MIN_USER
$MIN_PW
EOF
# Esperado: app-uploads/ keycloak-backups/ loki-chunks/ tempo-traces/
unset MIN_USER MIN_PW
```

### 12.4 Restore: re-criar `.bootstrap-creds` a partir do Vault

```bash
# k8s-host — port-forward Vault (mesmo pattern §11.4)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset MIN_USER MIN_PW VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

MIN_USER=$(vault kv get -field=username secret/standalone/minio/root)
MIN_PW=$(vault kv get -field=password secret/standalone/minio/root)

ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87 \
  "sudo tee /var/lib/uniplus/minio/.bootstrap-creds > /dev/null && \
   sudo chmod 600 /var/lib/uniplus/minio/.bootstrap-creds && \
   sudo chown root:root /var/lib/uniplus/minio/.bootstrap-creds" <<EOF
root_user=$MIN_USER
root_pw=$MIN_PW
EOF
```

### 12.5 Re-rodar bucket bootstrap manualmente

Se quiser pré-criar buckets adicionais sem rerunnar todo o bootstrap, ou se `step_data_bootstrap_minio_buckets` pulou por `.bootstrap-creds` ausente:

```bash
ssh ubuntu@10.0.2.87
# Substitua a lista de buckets conforme necessário
sudo docker run --rm -i --network host --entrypoint sh \
  quay.io/minio/mc:latest -c '
    set -e
    read -r U; read -r P
    mc --quiet alias set local http://10.0.2.87:9000 "$U" "$P"
    for b in keycloak-backups loki-chunks tempo-traces app-uploads; do
      mc mb --ignore-existing "local/$b"
    done
    mc ls local
  ' <<EOF
$(sudo grep ^root_user= /var/lib/uniplus/minio/.bootstrap-creds | cut -d= -f2)
$(sudo grep ^root_pw= /var/lib/uniplus/minio/.bootstrap-creds | cut -d= -f2)
EOF
```

### 12.6 Acesso ao Console UI (porta 9001)

**Acesso público via Traefik IngressRoute** (Issue #153, chart `platform/minio-console-proxy/`):

```
https://minio.standalone.portaluni.com.br
```

- Cert TLS LE prod (sem warning de browser)
- Login: `root_user` / `root_pw` custodiados em Vault `secret/standalone/minio/root`
- Acesso público — depende de senha forte; rotacionar regularmente (§12.7)

Como funciona internamente:
- Service `minio-console-proxy-uniplus-standalone-minio-console-proxy` no namespace `minio-console-proxy`: ClusterIP sem selector
- EndpointSlice manual com `endpoints[].addresses: [10.0.2.87]` apontando ao data-host (NÃO ExternalName — IP literal não resolve via DNS)
- IngressRoute Traefik faz proxy HTTPS terminando o cert + HTTP plain para o ClusterIP
- NetworkPolicy do Traefik tem egress para `10.0.2.87/32:9001` (override em `environments/standalone/values.yaml > networkPolicy.externalBackends`)

Acesso via SSH tunnel (fallback, se Traefik/cert-manager fora do ar):

```bash
# Do laptop (cria tunnel local 9001 → k8s-host:9001 → data-host:9001 via VCN)
ssh -L 9001:10.0.2.87:9001 ubuntu@164.152.53.29
# Em outro terminal: xdg-open http://localhost:9001
```

### 12.7 Rotacionar `root_pw`

```bash
# 1) Gerar nova senha + atualizar Vault
NEW_PW=$(openssl rand -hex 32)
vault kv put secret/standalone/minio/root \
  endpoint=http://10.0.2.87:9000 region=us-east-1 \
  username="$(vault kv get -field=username secret/standalone/minio/root)" \
  password="$NEW_PW"

# 2) Reconstituir .bootstrap-creds via §12.4 com NEW_PW

# 3) Re-rodar bootstrap (re-aplica EnvironmentFile com NEW_PW)
ssh ubuntu@10.0.2.87 "cd ~/uniplus-infra && ./scripts/bootstrap-standalone.sh --role=standalone-data"

# 4) Restart do MinIO para que MINIO_ROOT_PASSWORD reflita o novo valor
ssh ubuntu@10.0.2.87 "sudo systemctl restart uniplus-minio"

# 5) Validar — `mc admin info` deve aceitar a nova senha
unset NEW_PW
```

> Apps consumidoras (Fase 5) que cacheiem credenciais em ConfigMap/env precisam restart após rotação. ESO refresh é assíncrono — forçar sync via annotation se aplicável.

### 12.8 Backup e Restore

> Procedimento detalhado em sub-task da Story #118. Resumo:
>
> - **Backup:** snapshot LVM (`vg-minio/lv-minio`) + cópia dos chunks via `mc mirror local/<bucket> remote/...` para destino externo (institucional UNIFESSPA quando rede chegar).
> - **Restore:** parar `uniplus-minio`, restaurar volume via LVM snapshot ou re-importar via `mc mirror`, ajustar ownership `1000:1000`, iniciar serviço.
>
> **Em standalone, perda de MinIO afeta:** keycloak backups (recuperáveis via re-bootstrap do KC com data fresca), uploads de apps (perda de dados de usuário). Aceitável em validação; produção exige replicação cross-DC (não disponível em SNSD).

### 12.9 Troubleshooting

| Sintoma | Diagnóstico | Fix |
|---|---|---|
| `Access Denied` ao chamar `mc admin info` | `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` no env do container desatualizados ou typo no creds | Conferir `.bootstrap-creds` vs Vault; re-rodar §12.7 |
| Container falha startup com `Permission denied` em `/data` | Ownership do data dir ≠ `1000:1000` ou mode ≠ `750` | `sudo chown -R 1000:1000 /var/lib/uniplus/minio/data && sudo chmod 750 /var/lib/uniplus/minio/data` |
| `/minio/health/live` retorna 503 | MinIO ainda inicializando (1ª run formata `.minio.sys/`) ou drive corrupto | `sudo journalctl -u uniplus-minio -n 100`; aguardar até 90s |
| Console em `:9001` não responde | `--console-address 10.0.2.87:9001` não bind (porta em uso?) | `sudo ss -tlnp \| grep 9001`; se libre, restart `uniplus-minio` |
| `mc mb` retorna `BucketAlreadyOwnedByYou` | Bucket já existe (idempotência funcionando) | Sem ação — `--ignore-existing` evita o erro; se aparecer fora do flag, é OK |
| OOM kills do container | Workload excede heap default da JVM ausente (MinIO é Go, sem JVM); cgroup limit do host muito baixo | `docker stats uniplus-minio`; ajustar limits do systemd unit ou liberar memória |
| `mc alias set` retorna `Unable to verify SSL certificate` | TLS-mismatch ou endpoint errado | Confirmar endpoint `http://` (NÃO `https://`) — standalone usa PLAINTEXT |
| Disk full em `vg-minio` | Buckets crescem além do volume | `df -h /var/lib/uniplus/minio`; `mc admin info local` para uso por bucket; expandir LVM ou aplicar lifecycle/quota |

## 13. Kafka KRaft + SASL_SSL + SCRAM-SHA-512 (standalone)

Mensageria — `apache/kafka:4.2.0` (KRaft only; ZooKeeper removido na 4.0 GA) em container Docker gerenciado por systemd no data-host (`10.0.2.87:9092` para clientes, `:9093` para controller). Single-node combined (`process.roles=broker,controller`) com **SASL_SSL + SCRAM-SHA-512 + StandardAuthorizer** (ADR-009).

### 13.1 Kafka 4.2.0 — bootstrap automatizado

A função `step_data_setup_kafka` em `scripts/bootstrap-standalone.sh` provisiona, na ordem:

1. Diretórios:
   - `/var/lib/uniplus/kafka/data` (mode `750`, owner `1000:1000` — uid `appuser` no container, default user sem drop de privs)
   - `/etc/uniplus-kafka/certs/` (mode `755`, owner `root:root` — uid 1000 traverse para abrir PEMs)
   - `/etc/uniplus-kafka/config/` (mesmo padrão; contém `server.properties`)
2. `.bootstrap-creds` (root:root 600) em `/var/lib/uniplus/kafka/.bootstrap-creds` com `cluster_id` (UUID via `kafka-storage.sh random-uuid`) **e `admin_pw`** (32 bytes hex via `openssl rand`) — gerados **somente na primeira execução**. Mais robusto que o formato pré-ADR-009 que só tinha `cluster_id`.
3. **Cert PEM self-signed** em `/etc/uniplus-kafka/certs/` (validade **10 anos**), gerado por `openssl req` com SAN multi-tipo (`DNS:kafka.standalone.portaluni.com.br`, `DNS:localhost`, `IP:10.0.2.87`, `IP:127.0.0.1`). Auto-assinado → `ca.crt = server.crt` (cadeia de 1 nível). Bootstrap produz 4 arquivos:
   - `server.crt` (chown 1000:1000 mode 644) — cert isolado
   - `server.key` (chown 1000:1000 mode 600) — chave privada isolada
   - `ca.crt` (chown 1000:1000 mode 644) — CA pra distribuição a clients
   - `server.pem` (chown 1000:1000 mode 600) — **cert + key concatenados**, apontado por `ssl.keystore.location` no `server.properties`. Kafka 4.x exige bundle PEM (cert+key) para `ssl.keystore.type=PEM`; não há propriedade `*.key.location` separada — o broker lê o bundle e extrai cert/chave internamente.

   cert-manager fica para hml/prod com secret-sync para data-host (extensão K8s não atinge container fora do cluster).
4. **Format inicial do storage** via container ad-hoc com `--add-scram "SCRAM-SHA-512=[name=admin,password=$ADMIN_PW]"` — embarca admin SCRAM no `__cluster_metadata` log antes do primeiro start. Crítico: `--add-scram` só vale na 1ª formatação; re-format depois NÃO adiciona credenciais. Por isso o script roda format ANTES do `systemctl start`. Subsequentes runs: entrypoint do uniplus-kafka vê "already formatted" e skip.
5. `server.properties` em `/etc/uniplus-kafka/config/server.properties` (mode `600`, owner `1000:1000` — contém SCRAM password em cleartext na `listener.name.*.sasl.jaas.config`; broker uid 1000 lê, outros não). Inclui:
   - KRaft topology: `process.roles=broker,controller`, `node.id=1`, `controller.quorum.voters=1@10.0.2.87:9093`
   - Listeners: `SASL_SSL://10.0.2.87:9092` + `CONTROLLER://10.0.2.87:9093`; `inter.broker.listener.name=SASL_SSL`
   - SASL: `sasl.enabled.mechanisms=SCRAM-SHA-512`, JAAS inline para os 2 listeners
   - TLS: `ssl.keystore.type=PEM`, `ssl.keystore.location=/etc/kafka/secrets/server.pem` (bundle cert+key concatenados — Kafka 4.x não tem propriedade `*.key.location` separada), `ssl.truststore.type=PEM`, `ssl.truststore.location=/etc/kafka/secrets/ca.crt`, `ssl.client.auth=none`
   - AuthZ: `authorizer.class.name=org.apache.kafka.metadata.authorizer.StandardAuthorizer`, `super.users=User:admin`, `allow.everyone.if.no.acl.found=false` (fail-closed)
6. `admin.properties` em `/var/lib/uniplus/kafka/admin.properties` (mode `600`, owner `1000:1000` — uid do container precisa ler quando montado via `docker run -v`) — client config para `kafka-topics.sh`/`kafka-acls.sh`/`kafka-configs.sh`/`kafka-broker-api-versions.sh` rodando como admin via `--command-config`.
7. EnvironmentFile minimizado `/etc/uniplus-kafka.env` (root:root 600) com `CLUSTER_ID` (entrypoint exige) + `KAFKA_HEAP_OPTS="-Xmx1g -Xms1g"` (aspas obrigatórias — systemd EnvironmentFile parser tokeniza por espaço sem quoting).
8. `systemd` unit `/etc/systemd/system/uniplus-kafka.service` (`Restart=always`, `TimeoutStartSec=180`, `--network host`). Mount `config_dir → /mnt/shared/config:ro`; `KafkaDockerWrapper setup` do entrypoint pega o `server.properties` dali. Mount `certs_dir → /etc/kafka/secrets:ro`. Data dir → `/var/lib/kafka/data`.

**Por que `server.properties` em vez de env vars `KAFKA_*`:** a imagem `apache/kafka:4.2.0` traduz env vars `KAFKA_FOO_BAR_BAZ` → `foo.bar.baz`, mas a transformação não preserva hyphens. Properties como `listener.name.sasl_ssl.scram-sha-512.sasl.jaas.config` não podem ser representadas como env var. Solução oficial: `--mounted-configs-dir`.

**Idempotência:**

- `.bootstrap-creds`: preserva (validando que tem `admin_pw` — formato pré-ADR-009 falha com instrução); gera se ausente; aborta se `data/meta.properties` formatado sem creds.
- Certs: regenerados se ausentes; preservados em re-runs (clients podem ter cacheado o CA).
- Format: explícito em container ad-hoc com `--add-scram` na 1ª run; entrypoint do uniplus-kafka subsequente vê "already formatted" e skip.
- `server.properties` + `admin.properties` + EnvironmentFile + systemd unit: sempre re-aplicados.
- Serviço já ativo: bootstrap não reinicia.

**Verificação imediata pós-bootstrap (no data-host):**

```bash
sudo systemctl status uniplus-kafka

# kafka-broker-api-versions.sh agora exige cliente SASL_SSL — usar
# admin.properties (gerado pelo bootstrap) via container ad-hoc.
sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-broker-api-versions.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 \
  --command-config /tmp/admin.properties | head -3
# Esperado: lista de APIs (Produce, Fetch, ListOffsets, Metadata, ...)
```

### 13.1.1 Migração: PLAINTEXT (PR #137) → SASL_SSL (ADR-009)

Operadores com Kafka standalone deployado em PLAINTEXT (PR #137) — `.bootstrap-creds` contém só `cluster_id` sem `admin_pw` — precisam fazer **reset completo do storage** antes de re-rodar o bootstrap. Não há migração in-place porque:

- `--add-scram` só é honrado durante format inicial — re-format de storage existente NÃO adiciona credenciais
- Apagar e re-formatar com mesmo `cluster_id` exige data dir vazio (Kafka recusa format se houver `meta.properties`)
- Standalone é validação — perda de mensagens não é blocker

Procedimento (executar no data-host):

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87

# 1) Parar o serviço PLAINTEXT
sudo systemctl stop uniplus-kafka

# 2) Backup do .bootstrap-creds antigo (auditoria)
sudo cp /var/lib/uniplus/kafka/.bootstrap-creds \
        /var/lib/uniplus/kafka/.bootstrap-creds.pre-sasl.bak
sudo chmod 600 /var/lib/uniplus/kafka/.bootstrap-creds.pre-sasl.bak

# 3) Shred do creds atual + reset do data dir (perde tópicos + mensagens; standalone não usa)
sudo shred -u /var/lib/uniplus/kafka/.bootstrap-creds
sudo find /var/lib/uniplus/kafka/data/ -mindepth 1 -delete

# 4) Re-rodar bootstrap (gera novo cluster_id + admin_pw + cert + format com --add-scram)
cd ~/uniplus-infra && git pull --ff-only
./scripts/bootstrap-standalone.sh --role=standalone-data
```

Após o bootstrap concluir com sucesso, completar:

- Custodiar as **novas** credenciais via §13.2 (admin_pw em `secret/standalone/kafka/admin`, cluster_id em `secret/standalone/kafka/cluster` — o `cluster_id` antigo persiste no path antigo do Vault e pode ser deletado: `vault kv delete secret/standalone/kafka/cluster` antes do `kv put` novo, ou `vault kv metadata delete` para purge completo)
- Distribuir o novo `ca.crt` para qualquer cliente que tenha cacheado o antigo (em standalone single-host, normalmente apenas AKHQ futuro — não há clientes ativos hoje)
- Validar via §13.3

> Em hml/prod com mensagens reais, esse pattern não se aplica — exige procedimento de migração com reset gradual (broker novo SASL_SSL em paralelo, mirror via MirrorMaker 2, switchover de clients). Standalone aceita o reset porque não há state real.

### 13.2 Custódia das credenciais iniciais

> ⚠️ **CRÍTICO.** O `.bootstrap-creds` contém `admin_pw` (32 bytes hex) que é o segredo de acesso ao cluster. Custodiar no Vault + gestor institucional. `cluster_id` continua não-segredo (apenas identificador) — registrado em path separado para auditoria.

**Passo 1 — Ler creds no data-host:**

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87
sudo cat /var/lib/uniplus/kafka/.bootstrap-creds
# cluster_id=<UUID>
# admin_pw=<64 hex>
```

**Passo 2 — Salvar no Vault (executar do k8s-host):**

```bash
read -rsp "Cole admin_pw (do passo 1): " KAFKA_ADMIN_PW; echo
read -rsp "Cole cluster_id (do passo 1): " KAFKA_CID; echo

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault port-forward platform-vault-uniplus-standalone-0 8200:8200 \
  > /tmp/vault-pf.log 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null; unset KAFKA_ADMIN_PW KAFKA_CID VAULT_TOKEN VAULT_ADDR' EXIT
export VAULT_ADDR=http://127.0.0.1:8200
until curl -s --max-time 1 "$VAULT_ADDR/v1/sys/health" >/dev/null 2>&1; do sleep 1; done

read -rsp "Root token: " VAULT_TOKEN; echo
export VAULT_TOKEN

# Admin SCRAM (segredo + CA cert para clients)
CA_CERT=$(ssh ubuntu@10.0.2.87 "sudo cat /etc/uniplus-kafka/certs/ca.crt")
vault kv put secret/standalone/kafka/admin \
  username=admin \
  password="$KAFKA_ADMIN_PW" \
  bootstrap_servers=10.0.2.87:9092 \
  mechanism=SCRAM-SHA-512 \
  ca_cert="$CA_CERT"

# Cluster info (auditoria, não-segredo)
vault kv put secret/standalone/kafka/cluster \
  bootstrap_servers=10.0.2.87:9092 \
  cluster_id="$KAFKA_CID"

vault kv get secret/standalone/kafka/admin
vault kv get secret/standalone/kafka/cluster
unset CA_CERT
```

> Com `admin_pw` no Vault, considerar `shred -u .bootstrap-creds` no data-host. Trade-off: re-execução do bootstrap aborta (storage formatado sem creds); restauração via §13.4. Em standalone, manter o file é defensável — apenas `root` no data-host lê.

### 13.3 Validação end-to-end (pod K8s → Kafka)

Confirma que pods do cluster K3s alcançam Kafka SASL_SSL no data-host. Pré-requisito: PR #125 aplicado (iptables FORWARD ACCEPT) + CA cert distribuível (de `secret/standalone/kafka/admin` ou direto do data-host).

**Executar no k8s-host:**

```bash
# 1) Conectividade TCP bruta
nc -zv 10.0.2.87 9092
# Esperado: succeeded (mas TCP succeeded != auth ok — segue passo 2)

# 2) Pod ad-hoc com cliente Kafka — produce + consume round-trip via SASL_SSL.
#    admin_pw lido do Vault via kubectl exec (não argv); admin.properties
#    montado via configmap efêmero criado just-in-time.
read -rsp "Root token: " TKN; echo

ADMIN_PW=$(sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; export VAULT_TOKEN="$T"; vault kv get -field=password secret/standalone/kafka/admin' \
  <<<"$TKN")
CA_CERT=$(sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; export VAULT_TOKEN="$T"; vault kv get -field=ca_cert secret/standalone/kafka/admin' \
  <<<"$TKN")
unset TKN

# Gera ConfigMap com client.properties + ca.crt (resource scoped ao smoke test)
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml create configmap kafka-smoke-client \
  --from-literal=client.properties="security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username=\"admin\" password=\"$ADMIN_PW\";
ssl.truststore.type=PEM
ssl.truststore.location=/tmp/cm/ca.crt
ssl.endpoint.identification.algorithm=" \
  --from-literal=ca.crt="$CA_CERT" \
  --dry-run=client -o yaml | sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f -
unset ADMIN_PW CA_CERT

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml run kafka-validation \
  --image=apache/kafka:4.2.0 --restart=Never --rm -i \
  --overrides='{"spec":{"containers":[{"name":"kafka-validation","image":"apache/kafka:4.2.0","command":["bash","-c","set -euo pipefail; BS=10.0.2.87:9092; CC=/tmp/cm/client.properties; /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --command-config $CC --create --topic uniplus-smoke --partitions 1 --replication-factor 1; echo hello-uniplus | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $BS --producer.config $CC --topic uniplus-smoke; /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $BS --consumer.config $CC --topic uniplus-smoke --from-beginning --max-messages 1 --timeout-ms 10000; /opt/kafka/bin/kafka-topics.sh --bootstrap-server $BS --command-config $CC --delete --topic uniplus-smoke"],"volumeMounts":[{"name":"cm","mountPath":"/tmp/cm","readOnly":true}]}],"volumes":[{"name":"cm","configMap":{"name":"kafka-smoke-client"}}]}}'

sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml delete configmap kafka-smoke-client
# Esperado: "hello-uniplus" no consumer; topic deletado
```

> O pattern com ConfigMap é necessário porque `kubectl run` simples não monta secrets. Em produção (Fase 5), apps consomem `kafka-credentials-<app>` via ESO — secret K8s direto, sem ConfigMap.

### 13.4 Restore: re-criar `.bootstrap-creds` a partir do Vault

Se `.bootstrap-creds` foi shredded ou perdido, recuperar `cluster_id` (de `meta.properties` no data dir OU do Vault) e `admin_pw` (do Vault):

```bash
# k8s-host — port-forward + leitura dos secrets
read -rsp "Root token: " VAULT_TOKEN; echo

CID=$(sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; export VAULT_TOKEN="$T"; vault kv get -field=cluster_id secret/standalone/kafka/cluster' \
  <<<"$VAULT_TOKEN")
APW=$(sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; export VAULT_TOKEN="$T"; vault kv get -field=password secret/standalone/kafka/admin' \
  <<<"$VAULT_TOKEN")

# Sanidade: cluster_id do Vault deve bater com meta.properties (se existir)
META_CID=$(ssh ubuntu@10.0.2.87 \
  "sudo grep '^cluster.id=' /var/lib/uniplus/kafka/data/meta.properties 2>/dev/null | cut -d= -f2")
if [[ -n "$META_CID" && "$META_CID" != "$CID" ]]; then
  echo "ERRO: cluster_id do Vault ($CID) ≠ meta.properties ($META_CID)" >&2
  return 1 2>/dev/null || exit 1
fi

# Reconstituir
ssh -i ~/.ssh/id_ed25519 ubuntu@10.0.2.87 \
  "sudo tee /var/lib/uniplus/kafka/.bootstrap-creds > /dev/null && \
   sudo chmod 600 /var/lib/uniplus/kafka/.bootstrap-creds && \
   sudo chown root:root /var/lib/uniplus/kafka/.bootstrap-creds" <<EOF
cluster_id=$CID
admin_pw=$APW
EOF
unset VAULT_TOKEN CID APW META_CID
```

> ⚠️ Restaurar `cluster_id` **sem** `meta.properties` correspondente significa storage perdido. Re-rodar bootstrap recriará `meta.properties`, mas **todos os tópicos e mensagens são perdidos**. Em standalone, mensageria é volátil (single-broker, sem replicação).

### 13.5 Operações comuns (admin)

Todos os exemplos rodam o cliente em container ad-hoc com mount do `admin.properties`. Substituir pelo CA cert no path do truststore.

**Listar topics:**

```bash
sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-topics.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties --list
```

**Criar tópico com partições e retenção customizadas:**

```bash
sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-topics.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties \
  --create --topic uniplus.events.candidato.inscrito \
  --partitions 3 --replication-factor 1 \
  --config retention.ms=604800000  # 7 dias
```

**Criar user SCRAM per-app (Fase 5):**

```bash
APP_PW=$(openssl rand -hex 32)

sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-configs.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties \
  --alter --add-config "SCRAM-SHA-512=[password=$APP_PW]" \
  --entity-type users --entity-name uniplus-portal-svc

# Custodiar APP_PW em secret/standalone/kafka/uniplus-portal-svc
unset APP_PW
```

**Adicionar ACLs (producer + consumer prefixed):**

```bash
sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-acls.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties \
  --add --allow-principal User:uniplus-portal-svc \
  --producer --topic uniplus.events. --resource-pattern-type prefixed

sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-acls.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties \
  --add --allow-principal User:uniplus-portal-svc \
  --consumer --topic uniplus.events. --resource-pattern-type prefixed \
  --group uniplus-portal.
```

**Inspecionar consumer groups:**

```bash
sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-consumer-groups.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties \
  --describe --group uniplus-portal-consumer
```

### 13.6 Rotacionar admin password

Operação não-trivial — admin SCRAM está embarcada no `__cluster_metadata` log via `--add-scram` da formatação inicial. Rotação demanda `ALTER USER` no Kafka + atualização do `server.properties` + restart do broker.

> ⚠️ **Trade-off de segurança:** o passo 1 expõe `$NEW_PW` em `/proc/<pid>/cmdline` durante ~1s — `kafka-configs.sh --add-config` exige password inline (Kafka 4.x não aceita stdin/arquivo para esse parâmetro), mesmo trade-off do `--add-scram` durante format inicial documentado no script bootstrap. Janela curta + namespace de container descartável + acesso restrito ao data-host (root/ubuntu via SSH key) tornam aceitável em standalone. Para hml/prod considerar: (a) rolling restart com novo broker SASL_SSL e migração de users, ou (b) ferramentas de admin com `kafka-storage.sh format` em data dir limpo (downtime + perda de ACLs).

```bash
# 1) Gerar nova senha + ALTER user no Kafka
NEW_PW=$(openssl rand -hex 32)

ssh ubuntu@10.0.2.87 "sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-configs.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties \
  --alter --add-config 'SCRAM-SHA-512=[password=$NEW_PW]' \
  --entity-type users --entity-name admin"

# 2) Atualizar Vault
read -rsp "Root token: " TKN; echo
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; read -r P; export VAULT_TOKEN="$T"; vault kv patch secret/standalone/kafka/admin password="$P"' \
  <<EOF
$TKN
$NEW_PW
EOF

# 3) Atualizar .bootstrap-creds + re-rodar bootstrap (regera server.properties
#    + admin.properties com a nova senha)
ssh ubuntu@10.0.2.87 "sudo sed -i 's/^admin_pw=.*$/admin_pw=$NEW_PW/' /var/lib/uniplus/kafka/.bootstrap-creds"
ssh ubuntu@10.0.2.87 "cd ~/uniplus-infra && ./scripts/bootstrap-standalone.sh --role=standalone-data"

# 4) Restart do broker para que o JAAS inline em server.properties recarregue
ssh ubuntu@10.0.2.87 "sudo systemctl restart uniplus-kafka"

# 5) Validar com nova senha (admin.properties já regenerado)
ssh ubuntu@10.0.2.87 "sudo docker run --rm --network host \
  -v /var/lib/uniplus/kafka/admin.properties:/tmp/admin.properties:ro \
  -v /etc/uniplus-kafka/certs/ca.crt:/etc/uniplus-kafka/certs/ca.crt:ro \
  --entrypoint /opt/kafka/bin/kafka-broker-api-versions.sh \
  apache/kafka:4.2.0 \
  --bootstrap-server 10.0.2.87:9092 --command-config /tmp/admin.properties | head -1"

unset NEW_PW TKN
```

> Apps consumidoras (Fase 5) usando user `admin` precisam restart com a nova senha. Apps com user dedicado (recomendado) não são afetadas.

### 13.7 Rotacionar cert TLS

Self-signed estático com validade 10 anos — rotação programática não está prevista em standalone. Se necessário (compromisso de chave, expiração antecipada):

```bash
# 1) Backup do cert antigo
ssh ubuntu@10.0.2.87 "sudo cp /etc/uniplus-kafka/certs/server.crt /etc/uniplus-kafka/certs/server.crt.bak.$(date +%s)"

# 2) Apagar para forçar regeneração no próximo bootstrap
ssh ubuntu@10.0.2.87 "sudo rm /etc/uniplus-kafka/certs/server.{crt,key} /etc/uniplus-kafka/certs/ca.crt"

# 3) Re-rodar bootstrap (gera novo cert)
ssh ubuntu@10.0.2.87 "cd ~/uniplus-infra && ./scripts/bootstrap-standalone.sh --role=standalone-data"

# 4) Atualizar ca_cert no Vault
NEW_CA=$(ssh ubuntu@10.0.2.87 "sudo cat /etc/uniplus-kafka/certs/ca.crt")
read -rsp "Root token: " TKN; echo
sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
  -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; CERT=$(cat); export VAULT_TOKEN="$T"; vault kv patch secret/standalone/kafka/admin ca_cert="$CERT"' <<EOF
$TKN
$NEW_CA
EOF

# 5) Restart broker (carrega novo cert)
ssh ubuntu@10.0.2.87 "sudo systemctl restart uniplus-kafka"

# 6) Apps consumidoras (Fase 5) precisam refresh do CA via ESO/configmap
unset NEW_CA TKN
```

### 13.8 Backup e Restore

> Procedimento detalhado em sub-task da Story #118. Resumo:
>
> - **Backup:** snapshot LVM (`vg-kafka/lv-kafka`) ou cópia do data dir após `systemctl stop uniplus-kafka`. **Backup ao vivo de Kafka NÃO é confiável** — cópia inconsistente entre arquivos de log e índices. Sempre stop antes de copiar. **Incluir `/etc/uniplus-kafka/certs/` e `/etc/uniplus-kafka/config/server.properties` no backup** — `cluster_id` em `meta.properties` é pareado com cert que validou clients existentes.
> - **Restore:** parar `uniplus-kafka`, restaurar volume + certs + server.properties, ajustar ownership (data 1000:1000, certs 1000:1000, server.properties 1000:1000 mode 600), iniciar serviço.
>
> **Em standalone, perda de Kafka afeta:** mensagens em-vôo (perda dependendo do consumer offset) + ACLs/users SCRAM (recriáveis se admin password preservado). Aceitável em validação.

### 13.9 Pattern de migração para hml/prod

ADR-009 documenta os deltas previstos:

- **Cert:** self-signed → cert-manager Issuer (interno ou Let's Encrypt) + secret-sync para data-host (CronJob extrai cert renovado a cada 30 dias e SCP para `/etc/uniplus-kafka/certs/`)
- **Cluster:** single-node → 3 brokers HA com `replication.factor=3`, `min.insync.replicas=2`
- **Auth:** SASL/SCRAM-SHA-512 mantém-se; mTLS opcional adicionado em listener separado para inter-broker
- **AuthZ:** ACLs persistem no `__cluster_metadata` log; só copiar; verificar com `kafka-acls.sh --list`

> Não implementar em standalone — apenas registrar como follow-up para Story HA.

### 13.10 Troubleshooting

| Sintoma | Diagnóstico | Fix |
|---|---|---|
| Container reinicia em loop com `Cluster ID mismatch` | `CLUSTER_ID` no env diferente do `cluster.id` em `meta.properties` | Restaurar `.bootstrap-creds` correto via §13.4 |
| `Authentication failed during authentication` | Senha SCRAM no `server.properties`/admin.properties dessincronizada do `__cluster_metadata` | Conferir `vault kv get` vs `.bootstrap-creds`; se mismatch, rotacionar via §13.6 |
| `SSL handshake failed: PKIX path building failed` | Cliente não tem o CA no truststore | Distribuir `/etc/uniplus-kafka/certs/ca.crt` para o cliente; conferir `ssl.truststore.location` no client.properties |
| `Connection to node -1 failed` em smoke test | Faltou `--command-config` (cliente tentando PLAINTEXT contra listener SASL_SSL) | Sempre passar `--command-config admin.properties` em CLI tools |
| `ACL DENIED` para user existente | ACL não criada ou pattern errado (literal vs prefixed) | `kafka-acls.sh --list` filtrando por principal; recriar ACL com `--resource-pattern-type prefixed` se aplicável |
| `endpoint identification algorithm` failure no client | Cliente verificando hostname no cert; standalone usa SAN IP/DNS específicos | `ssl.endpoint.identification.algorithm=` (vazio) no client.properties |
| `OutOfMemoryError: Java heap space` | `KAFKA_HEAP_OPTS=-Xmx1g` insuficiente | Aumentar `-Xmx` no EnvironmentFile (manter aspas); restart |
| `nc -zv 10.0.2.87 9092` succeeded mas SASL_SSL falha | TCP OK, mas auth/cert problem | `journalctl -u uniplus-kafka -n 100`; conferir `server.properties` perms (600 chown 1000:1000); conferir `ca.crt` legível pelo client |
| Cert expirado (ano 2036+) | Validade self-signed esgotou | Rotacionar via §13.7; alertar em monitoring quando < 30 dias |
| `KRaft metadata controller is not yet ready` | Cold start ou storage corrupto | Aguardar até 180s; se persiste, conferir `__cluster_metadata-0/` |
| Disk full em `vg-kafka` | Logs cresceram além do volume | `df -h /var/lib/uniplus/kafka`; aplicar `retention.ms`/`retention.bytes` por topic; expandir LVM |

## 14. AKHQ — Web UI do Kafka (standalone)

Web UI de gerenciamento do cluster Kafka SASL_SSL — chart `apps/kafka-ui/` (issue #139). AKHQ 0.27.x, Micronaut OIDC integrado ao realm `uniplus` do Keycloak. Pré-requisitos: §13 Kafka SASL_SSL ativo (admin SCRAM em `secret/standalone/kafka/admin`) + §10 Keycloak ativo (realm `uniplus` importado).

### 14.1 Pré-flight: client OIDC + JWT signing + custódia

3 segredos precisam ser custodiados em Vault antes do ArgoCD reconciliar o chart kafka-ui:

1. `secret/standalone/keycloak/clients/kafka-ui` — `client_secret` (gerado pelo realm import)
2. `secret/standalone/kafka-ui/jwt` — `signing_secret` (gerado pelo operador, 32 bytes hex)
3. `secret/standalone/kafka/admin` — admin SCRAM Kafka (já custodiado em §13.2)

Sem (1) ou (2), os ESOs ficam em `SecretNotFound` e AKHQ trava em `CreateContainerConfigError`.

```bash
kc() { sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }
```

**Passo 1 — Garantir que o realm `uniplus` tem o client `kafka-ui` + grupos.**

Realm já existente (deploy pré-PR #142) — Keycloak `start --import-realm` skip se realm existe. Adicionar via `kcadm.sh` (operação cirúrgica, sem perder customizações via Admin UI):

```bash
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  set -e
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth \
    --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  # 1.1 Criar grupos /admins/kafka e /users/uniplus (idempotente — ignora se existem).
  # NOTA: container ghcr.io/.../uniplus-keycloak:26.6.1-0 herda RHEL 9 minimal
  # do upstream Keycloak e NÃO tem awk/jq/python — usar grep+cut. Pattern para
  # extrair ID por name no CSV.
  for GP in "admins/kafka" "users/uniplus"; do
    PARENT=${GP%/*}; CHILD=${GP##*/}
    /opt/keycloak/bin/kcadm.sh create groups -r uniplus -s name="$PARENT" 2>/dev/null || true
    PID=$(/opt/keycloak/bin/kcadm.sh get groups -r uniplus --fields id,name --format csv --noquotes | grep -E ",${PARENT}\$" | cut -d, -f1 | head -1)
    /opt/keycloak/bin/kcadm.sh create groups/$PID/children -r uniplus -s name="$CHILD" 2>/dev/null || true
  done

  # 1.2 Criar client kafka-ui confidential (idempotente)
  EXISTING=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=kafka-ui --fields id --format csv --noquotes | tail -1)
  if [ -z "$EXISTING" ]; then
    /opt/keycloak/bin/kcadm.sh create clients -r uniplus -f - <<JSON
{
  "clientId": "kafka-ui",
  "name": "AKHQ — Kafka Web UI (admin)",
  "enabled": true, "protocol": "openid-connect",
  "publicClient": false, "standardFlowEnabled": true,
  "implicitFlowEnabled": false, "directAccessGrantsEnabled": false,
  "serviceAccountsEnabled": false, "frontchannelLogout": true,
  "redirectUris": ["https://kafka-ui.standalone.portaluni.com.br/oauth/callback/keycloak"],
  "webOrigins": ["https://kafka-ui.standalone.portaluni.com.br"],
  "attributes": { "post.logout.redirect.uris": "+" },
  "defaultClientScopes": ["web-origins","acr","profile","roles","email"]
}
JSON
    CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=kafka-ui --fields id --format csv --noquotes | tail -1)
    # 1.3 Mapper groups (full path)
    /opt/keycloak/bin/kcadm.sh create clients/$CID/protocol-mappers/models -r uniplus -f - <<JSON
{
  "name": "groups", "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "consentRequired": false,
  "config": { "full.path": "true", "id.token.claim": "true",
              "access.token.claim": "true", "userinfo.token.claim": "true",
              "claim.name": "groups" }
}
JSON
  fi
'
```

> Em deploys novos (sem realm prévio), o realm import cobre tudo automaticamente via `apps/keycloak-replica/files/uniplus-realm.json` — esse passo 1 é noop. Para forçar re-import completo (perdendo mudanças via Admin UI), seguir §10.5.

**Passo 2 — Recuperar o client_secret + custodiar:**

```bash
KAFKA_UI_SECRET=$(kc exec -n uniplus deploy/keycloak-replica-uniplus-standalone -- bash -c '
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=kafka-ui --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r uniplus --fields value --format csv --noquotes | tail -1
')
echo "kafka-ui client_secret: ${KAFKA_UI_SECRET:0:8}...(redacted)"
```

**Passo 3 — Gerar JWT signing secret (32 bytes hex aleatório):**

```bash
JWT_SECRET=$(openssl rand -hex 32)
```

**Passo 4 — Custodiar ambos em Vault (k8s-host):**

```bash
read -rsp "Root token: " VAULT_TOKEN; echo

# OIDC client_secret
kc -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; read -r S; export VAULT_TOKEN="$T"; vault kv put secret/standalone/keycloak/clients/kafka-ui client_secret="$S"' \
  <<EOF
$VAULT_TOKEN
$KAFKA_UI_SECRET
EOF

# JWT signing secret
kc -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; read -r S; export VAULT_TOKEN="$T"; vault kv put secret/standalone/kafka-ui/jwt signing_secret="$S"' \
  <<EOF
$VAULT_TOKEN
$JWT_SECRET
EOF

unset KAFKA_UI_SECRET JWT_SECRET VAULT_TOKEN
```

**Passo 5 — ArgoCD reconcilia o chart kafka-ui automaticamente** após os 3 ESOs sintetizarem os Secrets K8s (`<release>-kafka-admin`, `<release>-oidc-client`, `<release>-jwt`).

### 14.2 Adicionar usuários aos grupos /admins/kafka e /users/uniplus

Realm import já cria os grupos vazios. Adicionar membros:

```bash
# Via kcadm (CLI no pod Keycloak):
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  # Criar usuário (ou pular se já existe via Gov.br federado)
  /opt/keycloak/bin/kcadm.sh create users -r uniplus \
    -s username=jeferson.ferreira -s email=jeferson.ferreira@unifesspa.edu.br \
    -s firstName=Jeferson -s lastName="Ferreira da Silva" -s enabled=true || true

  # Buscar IDs do user e do grupo /admins/kafka
  USER_ID=$(/opt/keycloak/bin/kcadm.sh get users -r uniplus -q username=jeferson.ferreira \
    --fields id --format csv --noquotes | tail -1)
  GROUP_ID=$(/opt/keycloak/bin/kcadm.sh get groups -r uniplus \
    --fields id,path --format csv --noquotes | grep "/admins/kafka" | cut -d, -f1)

  # Adicionar
  /opt/keycloak/bin/kcadm.sh update users/$USER_ID/groups/$GROUP_ID -r uniplus -s userId=$USER_ID -s groupId=$GROUP_ID
'
```

Ou via Admin UI: `Users → <user> → Groups → Join /admins/kafka`.

### 14.3 Smoke test end-to-end

```bash
# 1) ESOs sincronizaram
kc get externalsecret -n uniplus | grep kafka-ui
# Esperado: <release>-kafka-admin SecretSynced=True
#           <release>-oidc-client  SecretSynced=True

# 2) Pod Running 1/1
kc get pod -n uniplus -l app.kubernetes.io/name=kafka-ui
# Esperado: 1/1 Running

# 3) Logs limpos (sem erros de kafka conn ou OIDC discovery)
kc logs -n uniplus -l app.kubernetes.io/name=kafka-ui --tail=100 | \
  grep -E "ERROR|Bound to|Started|OIDC"
# Esperado: "Server Started" (Micronaut), bound em 0.0.0.0:8080

# 4) Health endpoint
kc exec -n uniplus -l app.kubernetes.io/name=kafka-ui -- \
  curl -sf http://localhost:8080/health
# Esperado: {"status":"UP"}

# 5) Login real (do laptop):
xdg-open https://kafka-ui.standalone.portaluni.com.br
# - Aceitar warning de cert (LE staging)
# - Click "Login Uni+" → redireciona para Keycloak
# - Autenticar com user que tem membership /admins/kafka
# - Após callback, ver dropdown "standalone" no canto superior + lista de tópicos
```

### 14.4 Rotacionar client_secret

```bash
# 1) Regenerar no Keycloak via Admin API
NEW_SECRET=$(kc exec -n uniplus deploy/keycloak-replica-uniplus-standalone -- bash -c '
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=kafka-ui --fields id --format csv --noquotes | tail -1)
  /opt/keycloak/bin/kcadm.sh create clients/$CID/client-secret -r uniplus \
    --fields value --format csv --noquotes | tail -1
')

# 2) Atualizar Vault
read -rsp "Root token: " TKN; echo
kc -n vault exec -i platform-vault-uniplus-standalone-0 -- \
  sh -c 'read -r T; read -r S; export VAULT_TOKEN="$T"; vault kv put secret/standalone/keycloak/clients/kafka-ui client_secret="$S"' \
  <<EOF
$TKN
$NEW_SECRET
EOF

# 3) Forçar refresh do ESO (default refreshInterval=1h)
kc annotate externalsecret -n uniplus \
  $(kc get externalsecret -n uniplus -o name | grep oidc-client) \
  force-sync="$(date +%s)" --overwrite

# 4) Restart do AKHQ pra reler env
kc rollout restart deployment -n uniplus -l app.kubernetes.io/name=kafka-ui

unset NEW_SECRET TKN
```

### 14.5 Troubleshooting

| Sintoma | Diagnóstico | Fix |
|---|---|---|
| Pod `CreateContainerConfigError: secret <release>-oidc-client not found` | ESO `<release>-oidc-client` ainda não sincronizou — secret/standalone/keycloak/clients/kafka-ui ausente em Vault | Rodar §14.1 (custódia do client_secret) |
| Pod `CreateContainerConfigError: secret <release>-jwt not found` | ESO JWT ainda não sintetizou — secret/standalone/kafka-ui/jwt ausente em Vault | Rodar §14.1 passo 3+4 (gerar + custodiar JWT signing secret) |
| Pod `CreateContainerConfigError: secret <release>-kafka-admin not found` | ESO ainda não sintetizou — secret/standalone/kafka/admin ausente em Vault | Rodar §13.2 (custódia admin SCRAM Kafka) |
| AKHQ logs: `org.apache.kafka.common.errors.SslAuthenticationException: SSL handshake failed` | CA cert PEM ausente no Secret kafka-admin (key `ca.crt` faltando) | `vault kv get secret/standalone/kafka/admin` confere se `ca_cert` está populado; rodar §13.2 step 2 incluindo `ca_cert=$(ssh ...sudo cat /etc/uniplus-kafka/certs/ca.crt)` |
| AKHQ pod CrashLoopBackOff com `PKIX path building failed: unable to find valid certification path to requested target` no startup (DefaultOpenIdProviderMetadataFetcher) | OIDC issuer (Keycloak) usa cert que JDK do AKHQ não confia. Em standalone com `letsencrypt-staging` o JDK não tem o root staging no cacerts. | Promover Keycloak para `letsencrypt-prod` via §10.6 (preferido) OU adicionar LE staging CA ao truststore do AKHQ via init container — issue de hardening separada |
| Login redireciona pro Keycloak mas após callback retorna 401/Forbidden no AKHQ | Membership do user no grupo `/admins/kafka` ausente OU mapper `groups` no client kafka-ui ausente/quebrado | Confirmar grupo via Admin UI; verificar `kc get configmap -n uniplus <release>-config -o yaml` se `claim.name=groups` no protocolMapper |
| AKHQ logs: `Connection to node -1 failed: Authentication failed: Invalid username or password` | Senha SCRAM em Vault desatualizada vs Kafka runtime | Rodar §13.6 (rotação admin Kafka) — sincroniza Vault + restart broker; depois forçar refresh ESO `kafka-admin` |
| `redirect_uri did not match` no Keycloak | URI no realm ≠ `https://kafka-ui.standalone.portaluni.com.br/oauth/callback/keycloak` | Conferir `redirectUris` no client `kafka-ui` (Admin UI ou kcadm); ajustar se domínio do `ingress.host` mudou |
| Browser warning permanente "Not secure" | Cert LE staging — esperado em validação | Promover para `letsencrypt-prod` (alterar `clusterIssuer` em `environments/standalone/values.yaml`) — mesmo procedimento §10.6 do Keycloak |

---

## 15. Apicurio Registry — Schema Registry (standalone)

Schema/API artifact registry compatível com a Confluent Schema Registry API — chart `apps/apicurio-registry/` (issue #152). Apicurio 3.2.4, storage SQL no Postgres standalone (DB `apicurio`), autenticação OIDC via realm `uniplus` com role-based authorization. Pré-requisitos: §9 Postgres ativo + §10 Keycloak ativo (realm `uniplus` importado).

### 15.1 Pré-flight: DB + client OIDC + custódia

3 itens precisam estar prontos antes do ArgoCD reconciliar o chart apicurio-registry:

1. **DB `apicurio`** — provisionada pelo `step_data_setup_apicurio_db` do `bootstrap-standalone.sh`
2. **`secret/standalone/postgres/apicurio`** — senha do role `apicurio` (custodiar a partir de `.bootstrap-creds-apicurio`)
3. **`secret/standalone/keycloak/clients/apicurio-registry`** — `client_secret` (gerado pelo realm import)

Sem (2) ou (3), os ESOs ficam em `SecretNotFound` e o pod trava em `CreateContainerConfigError`.

```bash
kc() { sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }
```

**Passo 1 — Provisionar DB no Postgres data-host.**

```bash
# No host data (10.0.2.87), executar a etapa apicurio do bootstrap.
# Role correto é `standalone-data` (validation do script aceita apenas
# `standalone-k8s` ou `standalone-data`).
# IMPORTANTE: NÃO usar `sudo ./scripts/bootstrap-standalone.sh` — o script
# aborta com `check_not_root` quando EUID=0 (usa sudo internamente para
# operações específicas). Executar como user normal (ubuntu).
ssh ubuntu@10.0.2.87 "cd /opt/uniplus-infra && ./scripts/bootstrap-standalone.sh \
  --role=standalone-data"
```

O step idempotente `step_data_setup_apicurio_db` cria role + database e preserva senhas existentes. Após primeira execução:

```bash
# Custodiar senha em Vault (mesmo pattern do §9.2):
ssh ubuntu@10.0.2.87 "sudo cat /var/lib/uniplus/postgres/.bootstrap-creds-apicurio"
# apicurio_pw=<HEX_64>

VAULT_TOKEN=hvs.xxx \
  vault kv put secret/standalone/postgres/apicurio \
    username=apicurio \
    password=<HEX_64>

# Após custódia confirmada (vault kv get OK), apagar o arquivo do data-host:
ssh ubuntu@10.0.2.87 "sudo shred -u /var/lib/uniplus/postgres/.bootstrap-creds-apicurio"
```

**Passo 2 — Adicionar client `apicurio-registry` ao realm uniplus** (idempotente — Keycloak skipa import se realm já existe).

Como em §14.1 do AKHQ, usar `kcadm.sh` para operação cirúrgica:

```bash
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  set -e
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth \
    --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  # Cria client se não existe (idempotente via grep)
  if ! /opt/keycloak/bin/kcadm.sh get clients -r uniplus --fields clientId 2>/dev/null \
       | grep -q apicurio-registry; then
    /opt/keycloak/bin/kcadm.sh create clients -r uniplus \
      -s clientId=apicurio-registry \
      -s name="Apicurio Registry" \
      -s enabled=true \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s directAccessGrantsEnabled=true \
      -s serviceAccountsEnabled=true \
      -s "redirectUris=[\"https://schema-registry.standalone.portaluni.com.br/*\"]" \
      -s "webOrigins=[\"https://schema-registry.standalone.portaluni.com.br\"]" \
      -s frontchannelLogout=true
    # Nota: directAccessGrantsEnabled=true habilita password grant para o
    # smoke do §15.4. Em prod, revisar — admin deve usar authorization code
    # + PKCE via UI ou kcadm direto. Espelha o realm.json do PR #155.
  fi

  # Adiciona mapper groups (full path)
  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=apicurio-registry --fields id --format csv --noquotes | tail -1)
  if ! /opt/keycloak/bin/kcadm.sh get clients/$CID/protocol-mappers/models -r uniplus 2>/dev/null \
       | grep -q "\"name\" : \"groups\""; then
    /opt/keycloak/bin/kcadm.sh create clients/$CID/protocol-mappers/models -r uniplus \
      -s name=groups \
      -s protocol=openid-connect \
      -s protocolMapper=oidc-group-membership-mapper \
      -s "config.\"full.path\"=true" \
      -s "config.\"id.token.claim\"=true" \
      -s "config.\"access.token.claim\"=true" \
      -s "config.\"userinfo.token.claim\"=true" \
      -s "config.\"claim.name\"=groups"
  fi
'
```

**Passo 3 — Recuperar `client_secret` e custodiar em Vault.**

O endpoint `clients/$CID/client-secret` é o único que retorna o valor efetivo do confidential client secret — `get clients --fields secret` retorna vazio (Keycloak não expõe o secret no list). Mesmo pattern do AKHQ §14.1.

```bash
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  set -e
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth \
    --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus \
    -q clientId=apicurio-registry --fields id --format csv --noquotes | tail -1)

  /opt/keycloak/bin/kcadm.sh get clients/$CID/client-secret -r uniplus \
    --fields value --format csv --noquotes | tail -1
' > /tmp/apicurio-cs

SECRET=$(cat /tmp/apicurio-cs)

VAULT_TOKEN=hvs.xxx \
  vault kv put secret/standalone/keycloak/clients/apicurio-registry \
    client_secret="$SECRET"

shred -u /tmp/apicurio-cs
```

### 15.2 Custódia: rotação ou restore de senha do DB

**Restore (manutenção/upgrade após shred):** se você executou `shred -u $DATA_BASE/postgres/.bootstrap-creds-apicurio` após custódia em Vault e precisa rodar `bootstrap-standalone.sh --role=standalone-data` de novo (manutenção, upgrade), o step Apicurio aborta com `role apicurio já existe mas .bootstrap-creds-apicurio ausente` (Codex P1 round 5 do PR #155). Restaure o arquivo a partir do Vault antes:

```bash
APICURIO_PW=$(VAULT_TOKEN=hvs.xxx vault kv get -field=password secret/standalone/postgres/apicurio)
ssh ubuntu@10.0.2.87 "sudo tee /var/lib/uniplus/postgres/.bootstrap-creds-apicurio > /dev/null <<EOF
apicurio_pw=$APICURIO_PW
EOF
sudo chmod 600 /var/lib/uniplus/postgres/.bootstrap-creds-apicurio
sudo chown root:root /var/lib/uniplus/postgres/.bootstrap-creds-apicurio"

# Agora pode rodar o bootstrap normalmente (sem sudo — script aborta
# com check_not_root se EUID=0; usa sudo internamente).
ssh ubuntu@10.0.2.87 "cd /opt/uniplus-infra && ./scripts/bootstrap-standalone.sh --role=standalone-data"

# Após confirmar success, shred novamente (idempotente).
```

**Rotação (compromise ou política 90d):**

```bash
# 1. Gerar nova senha
NEW_PW=$(openssl rand -hex 32)

# 2. Atualizar role no Postgres
ssh ubuntu@10.0.2.87 "sudo docker exec -e PGPASSWORD=<super_pw> uniplus-postgres \
  psql -U postgres -c \"ALTER ROLE apicurio WITH PASSWORD '$NEW_PW';\""

# 3. Atualizar Vault
VAULT_TOKEN=hvs.xxx \
  vault kv put secret/standalone/postgres/apicurio username=apicurio password="$NEW_PW"

# 4. Forçar refresh do ESO (default refreshInterval=1h).
# Nota sobre nomes: Helm renderiza fullname como
# `<Release.Name>-<Chart.Name>`. Em standalone o ApplicationSet
# (argocd/applicationset.yaml) gera release name `apicurio-registry-uniplus-standalone`,
# então o ExternalSecret de DB é
# `apicurio-registry-uniplus-standalone-apicurio-registry-db`. Mesmo
# pattern do keycloak-replica/AKHQ vistos em §10/§14.
kc annotate -n uniplus externalsecret apicurio-registry-uniplus-standalone-apicurio-registry-db \
  force-sync=$(date +%s) --overwrite

# 5. Restart do deployment para o pod pegar a nova senha (env é cacheada)
kc rollout restart -n uniplus deployment/apicurio-registry-uniplus-standalone-apicurio-registry
```

### 15.3 Smoke test pós-deploy

```bash
# Helm fullname em standalone: apicurio-registry-uniplus-standalone-apicurio-registry
# (Release.Name `apicurio-registry-uniplus-standalone` + Chart.Name `apicurio-registry`)
APICURIO_DEPLOY=apicurio-registry-uniplus-standalone-apicurio-registry

# 1. Pod healthy. Label seletor `app.kubernetes.io/name=apicurio-registry`
# (chart name) bate em qualquer release — não precisa do fullname.
kc get pods -n uniplus -l app.kubernetes.io/name=apicurio-registry
# READY 1/1, STATUS Running

# 2. System info (substitui /q/health/* — Apicurio 3.2.4 desabilita
# esses paths Quarkus default; use system/info como liveness/readiness
# proxy: 200 quando JDBC pool ativo + REST routing up).
kc exec -n uniplus "deploy/$APICURIO_DEPLOY" -- \
  curl -s http://localhost:8080/apis/registry/v3/system/info
# {"name":"Apicurio Registry (SQL)","description":"...","version":"3.2.4",...}

# 3. OIDC discovery alcançável (deve retornar 200 com issuer)
kc exec -n uniplus "deploy/$APICURIO_DEPLOY" -- \
  curl -s https://standalone.portaluni.com.br/auth/realms/uniplus/.well-known/openid-configuration | head -c 200

# 4. UI externa
curl -sk https://schema-registry.standalone.portaluni.com.br/ui/ -o /dev/null -w "%{http_code}\n"
# 200 (HTML)

# 5. API V3 — listar artifacts (anonymous OFF, deve retornar 401 sem JWT)
curl -sk https://schema-registry.standalone.portaluni.com.br/apis/registry/v3/groups/default/artifacts -o /dev/null -w "%{http_code}\n"
# 401 (esperado — auth obrigatória)

# 6. Confluent SR API V2 (compat) — mesmo path, retorna 401
curl -sk https://schema-registry.standalone.portaluni.com.br/apis/ccompat/v7/subjects -o /dev/null -w "%{http_code}\n"
# 401 (esperado)
```

Para teste de smoke autenticado (com JWT), seguir §15.4.

### 15.4 Bootstrap inicial: registrar primeiro schema

Apicurio aceita JWT do realm `uniplus` no header `Authorization: Bearer <token>`. Obter token via password grant (apenas em ambiente standalone — em prod usar service account com client credentials):

```bash
# Token via password grant — user em /admins/kafka tem role sr-admin
TOKEN=$(curl -sk -X POST \
  https://standalone.portaluni.com.br/auth/realms/uniplus/protocol/openid-connect/token \
  -d "grant_type=password" \
  -d "client_id=apicurio-registry" \
  -d "client_secret=$CLIENT_SECRET" \
  -d "username=jeferson.ferreira" \
  -d "password=$PW" \
  -d "scope=openid" \
  | jq -r .access_token)

# Registrar primeiro Avro schema via Confluent SR compat API
curl -sk -X POST \
  https://schema-registry.standalone.portaluni.com.br/apis/ccompat/v7/subjects/uniplus.events.smoke-value/versions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/vnd.schemaregistry.v1+json" \
  -d '{"schemaType":"AVRO","schema":"{\"type\":\"record\",\"name\":\"Smoke\",\"fields\":[{\"name\":\"id\",\"type\":\"string\"}]}"}'
# {"id":1}

# Listar subjects
curl -sk -H "Authorization: Bearer $TOKEN" \
  https://schema-registry.standalone.portaluni.com.br/apis/ccompat/v7/subjects
# ["uniplus.events.smoke-value"]
```

### 15.5 Troubleshooting

| Sintoma | Causa provável | Resolução |
|---|---|---|
| Pod `CreateContainerConfigError` | ESO não sintetizou Secret (Vault offline ou path errado) | `kc describe externalsecret -n uniplus apicurio-registry-uniplus-standalone-apicurio-registry-{db,oidc-client}` — checar `status.conditions`. Se `SecretNotFound`: confirmar Vault unsealed + path correto |
| Pod `CrashLoopBackOff`, log `Connection refused (...:5432)` | Egress Postgres bloqueado por NetworkPolicy | Validar `dataHostCIDR` em `environments/standalone/values.yaml` cobre `10.0.2.0/24` (default). Confirmar `uniplus-postgres` ativo no data-host |
| Pod `CrashLoopBackOff`, log `password authentication failed for user "apicurio"` | Senha em Vault diferente da no Postgres | Recuperar `apicurio_pw` do data-host (`.bootstrap-creds-apicurio` se ainda existe) ou rotacionar via §15.2 |
| Pod up mas `/q/health/ready` retorna 503 com `OIDC discovery failed` | Egress OIDC issuer bloqueado (default-deny) | Validar `oidcIssuerCIDR=164.152.53.29/32` em `environments/standalone/values.yaml`. Mesmo bug que §14.4 do AKHQ |
| 401 mesmo com JWT válido em `/admins/kafka` | Mapper groups não aplicado no client | `kc exec deploy/keycloak-replica-... -- /opt/keycloak/bin/kcadm.sh get clients/$CID/protocol-mappers/models -r uniplus` — adicionar mapper conforme §15.1 passo 2 |
| 403 "user has no roles" mesmo após login | `APICURIO_AUTH_ROLE_BASED_AUTHORIZATION` true mas claim path errado | Decode JWT (`jwt.io`) — verificar claim `groups` presente. Se ausente, mapper groups não está incluindo no access_token (config.access.token.claim=true falta) |
| UI carrega mas botões "Create artifact" cinza | Role mapeada como `sr-readonly` em vez de `sr-admin` | Verificar group do user no Keycloak: `Users → jeferson.ferreira → Groups`. Adicionar a `/admins/kafka` se ausente |
| `auth.apicur.io` aparece em logs OIDC | `QUARKUS_OIDC_AUTH_SERVER_URL` não setado — caiu no default Keycloak demo Red Hat | Validar `oidc.issuerUri` em `environments/standalone/values.yaml`. Sempre obrigatório — sem isso, Apicurio confia em IdP externo público |
| Browser warning "Not secure" no `schema-registry.standalone.portaluni.com.br` | Cert LE staging | Promover para `letsencrypt-prod` em `ingress.tls.certManager.clusterIssuer` (já é default no `environments/standalone/values.yaml` — checar override por engano) |

### 15.6 Pré-flight: client_secret das APIs Uni+ (uniplus-api-{portal,selecao,ingresso})

Cada uma das 3 APIs Uni+ (`uniplus-api-portal`, `uniplus-api-selecao`, `uniplus-api-ingresso`) usa **OIDC client_credentials** para obter access_token contra o realm `uniplus` e chamar a Apicurio Registry REST API (`schema-registry.standalone.portaluni.com.br`). O fluxo é puro M2M — sem login interativo, sem redirect, sem PKCE.

3 confidential clients foram declarados em `apps/keycloak-replica/files/uniplus-realm.json` na issue #163:

| clientId | Vault path do client_secret | Consumido por |
|---|---|---|
| `uniplus-api-portal` | `secret/standalone/keycloak/clients/uniplus-api-portal` | API Portal (`apps/uniplus-api-portal/templates/externalsecret.yaml` ESO 5) |
| `uniplus-api-selecao` | `secret/standalone/keycloak/clients/uniplus-api-selecao` | API Seleção (`apps/uniplus-api-selecao/templates/externalsecret.yaml` ESO 5) |
| `uniplus-api-ingresso` | `secret/standalone/keycloak/clients/uniplus-api-ingresso` | API Ingresso (`apps/uniplus-api-ingresso/templates/externalsecret.yaml` ESO 5) |

Sem `client_secret` em Vault, o ESO 5 fica em `SecretNotFound` e o pod da API trava em `CreateContainerConfigError` quando o Deployment passar a referenciar a env var (uniplus-api#358). Hoje (pré-Apicurio) a env não é montada — o ESO sintetiza o Secret no namespace por defesa em profundidade, mas o Deployment ignora.

Cada client tem dois `protocolMappers` que projetam no access_token: (a) `audience-apicurio-registry` (mapper `oidc-audience-mapper`) — adiciona `apicurio-registry` ao claim `aud`, (b) `groups-hardcoded-developer` (mapper `oidc-hardcoded-claim-mapper`) — projeta `groups: ["/users/uniplus"]` no token. O Apicurio (`apps/apicurio-registry/values.yaml` `roleBasedAuth.developerClaim`) mapeia `/users/uniplus` → role interna `sr-developer`.

```bash
kc() { sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }
```

**Passo 1 — Garantir os 3 clients no realm.**

**Cluster novo (fresh import):** o realm.json já carrega os 3 clients no `--import-realm` inicial. Skipar para o Passo 2.

**Cluster existente** (realm `uniplus` já importado anteriormente — Keycloak 26.x **skipa** re-import quando o realm existe): adicionar os 3 clients via `kcadm.sh` (mesmo pattern de §15.1 passo 2 e §14.1 passo 2). Idempotente:

```bash
kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c '
  set -e
  /opt/keycloak/bin/kcadm.sh config credentials \
    --server http://localhost:8080/auth \
    --realm master \
    --user "$KC_BOOTSTRAP_ADMIN_USERNAME" \
    --password "$KC_BOOTSTRAP_ADMIN_PASSWORD" >/dev/null

  for cid in uniplus-api-portal uniplus-api-selecao uniplus-api-ingresso; do
    if ! /opt/keycloak/bin/kcadm.sh get clients -r uniplus --fields clientId 2>/dev/null \
         | grep -q "\"clientId\" : \"$cid\""; then
      /opt/keycloak/bin/kcadm.sh create clients -r uniplus \
        -s clientId=$cid \
        -s name="Uni+ API $cid — Service Account (M2M)" \
        -s enabled=true \
        -s publicClient=false \
        -s standardFlowEnabled=false \
        -s implicitFlowEnabled=false \
        -s directAccessGrantsEnabled=false \
        -s serviceAccountsEnabled=true \
        -s frontchannelLogout=false \
        -s "redirectUris=[]" \
        -s "webOrigins=[]" \
        -s "attributes.\"access.token.lifespan\"=300"
    fi

    CID=$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus -q clientId=$cid --fields id --format csv --noquotes | tail -1)

    # Mapper 1: audience apicurio-registry
    if ! /opt/keycloak/bin/kcadm.sh get clients/$CID/protocol-mappers/models -r uniplus 2>/dev/null \
         | grep -q "\"name\" : \"audience-apicurio-registry\""; then
      /opt/keycloak/bin/kcadm.sh create clients/$CID/protocol-mappers/models -r uniplus \
        -s name=audience-apicurio-registry \
        -s protocol=openid-connect \
        -s protocolMapper=oidc-audience-mapper \
        -s "config.\"included.client.audience\"=apicurio-registry" \
        -s "config.\"id.token.claim\"=false" \
        -s "config.\"access.token.claim\"=true"
    fi

    # Mapper 2: groups hardcoded /users/uniplus → role sr-developer no Apicurio
    if ! /opt/keycloak/bin/kcadm.sh get clients/$CID/protocol-mappers/models -r uniplus 2>/dev/null \
         | grep -q "\"name\" : \"groups-hardcoded-developer\""; then
      /opt/keycloak/bin/kcadm.sh create clients/$CID/protocol-mappers/models -r uniplus \
        -s name=groups-hardcoded-developer \
        -s protocol=openid-connect \
        -s protocolMapper=oidc-hardcoded-claim-mapper \
        -s "config.\"claim.name\"=groups" \
        -s "config.\"claim.value\"=[\"/users/uniplus\"]" \
        -s "config.\"jsonType.label\"=JSON" \
        -s "config.\"id.token.claim\"=true" \
        -s "config.\"access.token.claim\"=true" \
        -s "config.\"userinfo.token.claim\"=true" \
        -s "config.\"access.tokenResponse.claim\"=false"
    fi
  done
'
```

> **Nota — restart do Pod:** mudar o `realm.json` em Git força um rollout via annotation `checksum/realm` (sha256sum do arquivo) — `helm upgrade` faz a mudança sozinho. Em **cluster existente** o realm já está populado em DB, então o restart **não tem efeito incremental** sobre clients/mappers — por isso o `kcadm.sh` acima é necessário.

**Passo 2 — Recuperar `client_secret` de cada client e custodiar em Vault.**

Mesmo pattern do §14.1 (kafka-ui) e §15.1 passo 3 (apicurio-registry). O endpoint `clients/$CID/client-secret` é o único que retorna o valor efetivo.

```bash
for cid in uniplus-api-portal uniplus-api-selecao uniplus-api-ingresso; do
  kc exec -n uniplus -i deploy/keycloak-replica-uniplus-standalone -- bash -c "
    set -e
    /opt/keycloak/bin/kcadm.sh config credentials \
      --server http://localhost:8080/auth \
      --realm master \
      --user \"\$KC_BOOTSTRAP_ADMIN_USERNAME\" \
      --password \"\$KC_BOOTSTRAP_ADMIN_PASSWORD\" >/dev/null

    CID=\$(/opt/keycloak/bin/kcadm.sh get clients -r uniplus \
      -q clientId=$cid --fields id --format csv --noquotes | tail -1)

    /opt/keycloak/bin/kcadm.sh get clients/\$CID/client-secret -r uniplus \
      --fields value --format csv --noquotes | tail -1
  " > /tmp/$cid-cs

  SECRET=$(cat /tmp/$cid-cs)

  VAULT_TOKEN=hvs.xxx \
    vault kv put secret/standalone/keycloak/clients/$cid \
      client_secret="$SECRET"

  shred -u /tmp/$cid-cs
done
```

**Passo 3 — Smoke test do fluxo client_credentials.**

Confirma que (a) o token endpoint aceita o `client_secret` recuperado, (b) o JWT retornado tem `aud=apicurio-registry` e `groups=["/users/uniplus"]`, (c) o claim `groups` é tratado como array (resultado do mapper com `jsonType.label=JSON`).

```bash
ISSUER="https://standalone.portaluni.com.br/auth/realms/uniplus"
for cid in uniplus-api-portal uniplus-api-selecao uniplus-api-ingresso; do
  CSECRET=$(VAULT_TOKEN=hvs.xxx vault kv get -field=client_secret secret/standalone/keycloak/clients/$cid)
  TOKEN=$(curl -s -X POST "$ISSUER/protocol/openid-connect/token" \
    -d "grant_type=client_credentials" \
    -d "client_id=$cid" \
    -d "client_secret=$CSECRET" \
    | jq -r .access_token)

  echo "=== $cid ==="
  # Decode payload (parte do meio do JWT, base64url)
  echo "$TOKEN" | cut -d. -f2 | tr '_-' '/+' \
    | awk '{ l=length($0)%4; if(l==2)$0=$0"=="; else if(l==3)$0=$0"="; print }' \
    | base64 -d 2>/dev/null \
    | jq '{aud, azp, groups, scope, sub}'
done
```

Saída esperada para cada cliente:

```json
{
  "aud": ["apicurio-registry", "account"],
  "azp": "uniplus-api-portal",
  "groups": ["/users/uniplus"],
  "scope": "profile email",
  "sub": "<uuid-do-service-account>"
}
```

**Passo 4 — Validar acesso à Apicurio com o token.**

```bash
# Re-declara ISSUER e recarrega client_secret de uniplus-api-portal.
# Sem isso, operador rodando este passo em shell novo (não na sequência
# do Passo 3) hit URL malformada ($ISSUER unset) ou 401 falso ($CSECRET
# vindo da última iteração do loop do Passo 3 — uniplus-api-ingresso),
# mascarando problemas reais de auth na Apicurio.
ISSUER="https://standalone.portaluni.com.br/auth/realms/uniplus"
PORTAL_SECRET=$(VAULT_TOKEN=hvs.xxx vault kv get \
  -field=client_secret secret/standalone/keycloak/clients/uniplus-api-portal)

TOKEN=$(curl -s -X POST "$ISSUER/protocol/openid-connect/token" \
  -d "grant_type=client_credentials" \
  -d "client_id=uniplus-api-portal" \
  -d "client_secret=$PORTAL_SECRET" | jq -r .access_token)

# Lista artifacts (deve retornar 200 OK e JSON, mesmo que vazio).
curl -s -H "Authorization: Bearer $TOKEN" \
  https://schema-registry.standalone.portaluni.com.br/apis/registry/v3/groups/default/artifacts | jq .
```

| Resposta | Diagnóstico |
|---|---|
| `200 OK` + JSON | OK — token válido, audience aceito, role developer suficiente |
| `401 Unauthorized` | Token inválido ou expirado. Re-rodar Passo 3 (lifespan = 300s) |
| `403 Forbidden` | Token válido mas role insuficiente. Decode `groups` no JWT — deve conter `/users/uniplus`; se ausente, mapper `groups-hardcoded-developer` não foi criado (re-rodar Passo 1) |

**Rotação do client_secret** segue o pattern de §14.4 (kafka-ui) — `kcadm.sh create clients/$CID/client-secret` regenera, depois `vault kv put` atualiza. ESO sincroniza no próximo refresh (1h padrão), e em seguida o Pod consumidor (Deployment da API) precisa ser rolled-restart para pegar a env var nova.

---

## 16. RedisInsight UI (standalone)

UI para inspecionar/admin o Redis standalone — chart `apps/redis-ui/` (issue #154). RedisInsight 2.74 com connection pré-setup via env vars apontando para o Redis systemd no data-host (`10.0.2.87:6379`). Pré-requisitos: §11 Redis ativo + Vault unsealed + Traefik com IngressRoute funcionando.

### 16.1 Pré-flight: htpasswd + custódia

RedisInsight 2.x **não tem auth nativa**. Proteção via Traefik `basicAuth` middleware com htpasswd custodiado em Vault.

**Passo 1 — Gerar htpasswd (bcrypt):**

```bash
# Gerar usuário + senha forte. Bcrypt obrigatório (Traefik não aceita md5/sha).
USERNAME=admin
PASSWORD=$(openssl rand -base64 24)
HTPASSWD=$(htpasswd -nbB "$USERNAME" "$PASSWORD")
echo "user=$USERNAME pass=$PASSWORD"
echo "htpasswd=$HTPASSWD"
```

**Passo 2 — Custodiar em Vault:**

```bash
kc() { sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }

kc -n vault exec platform-vault-uniplus-standalone-0 -- \
  env VAULT_TOKEN=hvs.xxx \
  vault kv put -tls-skip-verify secret/standalone/redis-ui/basic-auth \
    username="$USERNAME" \
    password="$PASSWORD" \
    htpasswd="$HTPASSWD"
```

A senha cleartext (`password`) fica como referência operacional para login no UI; a chave usada pelo ESO é `htpasswd` (sintetizada como `users` no Secret K8s consumido pelo middleware).

**Passo 3 — Forçar refresh do ESO + verificar pod:**

```bash
kc annotate -n uniplus externalsecret \
  redis-ui-uniplus-standalone-redis-ui-redis \
  redis-ui-uniplus-standalone-redis-ui-basic-auth \
  force-sync=$(date +%s) --overwrite

# Pod fica Ready quando ambos secrets sincronizam:
kc get pods -n uniplus -l app.kubernetes.io/name=redis-ui
```

### 16.2 Smoke test

```bash
# 1. Pod healthy
kc get pods -n uniplus -l app.kubernetes.io/name=redis-ui
# READY 1/1, STATUS Running

# 2. Health endpoint via port-forward (sem basic auth no path interno)
kc port-forward -n uniplus deploy/redis-ui-uniplus-standalone-redis-ui 5540:5540 &
sleep 2
curl -s http://localhost:5540/api/health
# {"status":"UP",...}
kill %1

# 3. UI HTTPS externa retorna 401 sem credenciais (basic auth ativo)
curl -sk https://redis-ui.standalone.portaluni.com.br/ -o /dev/null -w "%{http_code}\n"
# 401

# 4. Login funciona com user/pass do Vault
curl -sk -u "admin:<PASSWORD>" https://redis-ui.standalone.portaluni.com.br/api/health -w "\n%{http_code}\n"
# 200 (UI responde)

# 5. Conexão Redis pré-setup aparece no UI (browser)
xdg-open https://redis-ui.standalone.portaluni.com.br
# Login admin / <PASSWORD>
# Lista de databases mostra "standalone" (alias) com host=10.0.2.87:6379
```

### 16.3 Rotacionar senha basic auth

```bash
# 1. Gerar nova senha + htpasswd
NEW_PW=$(openssl rand -base64 24)
NEW_HTPASSWD=$(htpasswd -nbB admin "$NEW_PW")

# 2. Update Vault
kc -n vault exec platform-vault-uniplus-standalone-0 -- \
  env VAULT_TOKEN=hvs.xxx \
  vault kv put -tls-skip-verify secret/standalone/redis-ui/basic-auth \
    username=admin password="$NEW_PW" htpasswd="$NEW_HTPASSWD"

# 3. Force ESO refresh
kc annotate -n uniplus externalsecret \
  redis-ui-uniplus-standalone-redis-ui-basic-auth \
  force-sync=$(date +%s) --overwrite

# Traefik recarrega Middleware automaticamente (provider K8s watches CRDs).
# Browser exige re-login com nova senha em ~30s.
```

### 16.4 Troubleshooting

| Sintoma | Causa provável | Resolução |
|---|---|---|
| Pod `CreateContainerConfigError` | ESO não sintetizou Secret (Vault offline ou htpasswd ausente) | `kc describe externalsecret -n uniplus redis-ui-uniplus-standalone-redis-ui-{redis,basic-auth}` — checar `status.conditions`. Se `SecretNotFound`: confirmar Vault unsealed + paths corretos |
| Pod `CrashLoopBackOff`, log `Connection refused (...:6379)` | Egress Redis bloqueado por NetworkPolicy | Validar `dataHostCIDR=10.0.2.0/24` em `environments/standalone/values.yaml`. Confirmar `uniplus-redis` ativo no data-host |
| 401 mesmo com credenciais corretas | htpasswd em formato errado (md5/sha em vez de bcrypt) | Re-gerar com `htpasswd -nbB` (-B = bcrypt). Re-custodiar + force ESO refresh + restart Middleware via `kc rollout restart -n traefik deploy/...` (raramente necessário) |
| UI carrega mas conexão pré-setup ausente | RedisInsight não recriou conexões em restart (emptyDir limpo + env não foi re-aplicada) | `kc exec -n uniplus deploy/redis-ui-uniplus-standalone-redis-ui -- env \| grep RI_REDIS_` — confirmar env vars setadas. Se OK, `kc rollout restart deploy/redis-ui-uniplus-standalone-redis-ui` re-aplica setup |
| Login na UI mas `Connection failed` ao clicar no DB | Senha Redis errada no ESO ou Redis exigindo TLS | Validar senha em Vault `secret/standalone/redis/default` bate com `/etc/uniplus-redis/users.acl`. Se ok, RedisInsight 2.x default `RI_REDIS_TLS=false` (nosso config) — Redis standalone aceita plaintext na subnet privada |
| Browser warning "Not secure" | Cert LE staging ou expirado | Confirmar `clusterIssuer: letsencrypt-prod` em `environments/standalone/values.yaml`. `kc get certificate -n uniplus redis-ui-uniplus-standalone-redis-ui` deve estar `READY=True` |

---

## 17. Vault Transit bootstrap (standalone)

Chart `platform/vault-transit-bootstrap/` (issue [#219](https://github.com/unifesspa-edu-br/uniplus-infra/issues/219)) reconcilia declarativamente o engine `transit` no Vault local em cada deploy.

Recursos gerenciados:

- Mount `transit/` no Vault.
- Key `uniplus-idempotency-aesgcm` (AES-GCM-256, `deletion_allowed=false`, `exportable=false`).
- Policy `uniplus-api-transit` (apenas `update` em `transit/encrypt|decrypt/uniplus-idempotency-aesgcm`).
- Role K8s auth `uniplus-api` (bound à SA `uniplus-api`/ns `uniplus`, TTL token 1h).

O Job roda no namespace `vault-transit-bootstrap`, consome `VAULT_TOKEN` via ExternalSecret (ClusterSecretStore `vault-default`, path `secret/standalone/vault/root`) e executa o script `files/bootstrap-vault-transit.sh` embarcado como ConfigMap.

### 17.1 Verificar saúde

Obter o root token previamente do cofre institucional (`~/configs/uniplus-standalone/` no host do operador, ou gestor de segredos corporativo); jamais embarcar literal em documento ou pipeline.

```bash
# Substituir <k8s-host> pelo endereço SSH do operador e <root-token> pelo
# valor obtido localmente. Token nunca pode ser logado ou commitado.
ssh -i ~/.ssh/id_ed25519 ubuntu@<k8s-host> "
  sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml \
    -n vault exec -i platform-vault-uniplus-standalone-0 -- \
    sh -c 'export VAULT_TOKEN=<root-token>;
           echo --- secrets list ---;
           vault secrets list | grep transit;
           echo --- transit key ---;
           vault read transit/keys/uniplus-idempotency-aesgcm;
           echo --- auth role ---;
           vault read auth/kubernetes/role/uniplus-api;
           echo --- policy ---;
           vault policy read uniplus-api-transit'
"
```

Saída esperada (excerto):

- `transit/` aparece em `vault secrets list`.
- `transit/keys/uniplus-idempotency-aesgcm` mostra `type=aes256-gcm96`, `deletion_allowed=false`, `exportable=false`.
- `auth/kubernetes/role/uniplus-api` mostra `bound_service_account_names=[uniplus-api]`, `bound_service_account_namespaces=[uniplus]`, `policies=[uniplus-api-transit]`, `ttl=1h`.
- `uniplus-api-transit` lista as duas capabilities `update` em `transit/encrypt|decrypt/uniplus-idempotency-aesgcm`.

### 17.2 Rotacionar a key

```bash
vault write -f transit/keys/uniplus-idempotency-aesgcm/rotate
```

Vault Transit preserva todas as versões anteriores: requests de `decrypt` continuam decodificando ciphertexts antigos. Consumidores que querem re-encrypt para a versão mais nova podem chamar `vault write transit/rewrap/uniplus-idempotency-aesgcm ciphertext=...` ou aceitar que ciphertexts antigos permanecem na versão antiga até reescrita natural.

### 17.3 Revogar a role em incidente

```bash
vault delete auth/kubernetes/role/uniplus-api
```

Efeito imediato: novos logins K8s auth falham com `permission denied`. Pods existentes da `uniplus-api` continuam com tokens já emitidos (TTL 1h, sem renovação possível). Restartar os pods força nova autenticação que falha, e o `EncryptionOptionsValidator` da uniplus-api (PR [#401](https://github.com/unifesspa-edu-br/uniplus-api/pull/401) / [#403](https://github.com/unifesspa-edu-br/uniplus-api/pull/403)) já garante que pods sem auth válido caem em `CrashLoopBackOff` em vez de servir 500 silencioso.

Para reativar após mitigar o incidente: re-aplicar o chart (`argocd app sync platform-vault-transit-bootstrap-uniplus-standalone`).

### 17.4 Limpar manualmente (não-GitOps)

`helm uninstall` deleta o Job/CM/SA/ES/NP mas **não** remove o mount transit/key/policy/role do Vault — comportamento intencional para evitar perda de dados cifrados durante operações de manutenção do chart. Para cleanup completo (cenário raro: refactor da topologia de cifragem):

```bash
vault delete auth/kubernetes/role/uniplus-api
vault policy delete uniplus-api-transit
# Key só pode ser deletada após habilitar deletion_allowed:
vault write transit/keys/uniplus-idempotency-aesgcm/config deletion_allowed=true
vault delete transit/keys/uniplus-idempotency-aesgcm
vault secrets disable transit
```

### 17.5 Trade-off do token bootstrap

O `ExternalSecret` deste chart consome o **root token** do Vault em standalone. Isso é deliberadamente excessivo para o escopo de bootstrap (`sys/mounts`, `transit/*`, `sys/policies/acl`, `auth/kubernetes/role`) e deve ser reduzido antes da Fase 6. Plano em `platform/vault-transit-bootstrap/README.md`.

---

## 18. Wire-up uniplus-api → Vault Transit (standalone)

Issue [#220](https://github.com/unifesspa-edu-br/uniplus-infra/issues/220). Os 3 charts `apps/uniplus-api-{portal,selecao,ingresso}` em standalone passam a usar `Provider=vault` por padrão, consumindo a key `uniplus-idempotency-aesgcm` provisionada pelo chart `platform/vault-transit-bootstrap` (§17).

### 18.1 Topologia das ServiceAccounts

Cada chart cria sua própria ServiceAccount com nome FIXO:

- `uniplus-api-portal` (chart `apps/uniplus-api-portal`)
- `uniplus-api-selecao` (chart `apps/uniplus-api-selecao`)
- `uniplus-api-ingresso` (chart `apps/uniplus-api-ingresso`)

A role Kubernetes auth `uniplus-api` no Vault tem `bound_service_account_names=uniplus-api-portal,uniplus-api-selecao,uniplus-api-ingresso` (CSV, namespace `uniplus`) e `policies=[uniplus-api-transit]` — única role para os 3 charts.

### 18.2 Validar consumo via smoke E2E

```bash
export KEYCLOAK_CLIENT_SECRET=<apicurio-registry client_secret>
export KEYCLOAK_USERNAME=jeferson.ferreira
export KEYCLOAK_PASSWORD=<senha>

./scripts/smoke-encryption-e2e.sh
```

O script:

1. Obtém token OIDC do realm `uniplus` validando audience.
2. POST `/api/v1/selecao/editais` com `Idempotency-Key` UUID — exercita o `IdempotencyFilter` da uniplus-api que toca cifragem.
3. Espera HTTP 201/422 (ambos válidos — qualquer 5xx é regressão).
4. Lê audit log do Vault buscando entrada `transit/encrypt/uniplus-idempotency-aesgcm`.

Pré-requisito: audit device habilitado no Vault. Se ausente, o script pula o passo 4 com aviso. Para habilitar:

```bash
ssh -i ~/.ssh/id_ed25519 ubuntu@<k8s-host> "
  sudo kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n vault exec -i \
    platform-vault-uniplus-standalone-0 -- \
    env VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN=<root> \
    vault audit enable file file_path=/vault/audit/audit.log"
```

### 18.3 Inspecionar o Pod da uniplus-api

```bash
sudo kubectl -n uniplus describe pod uniplus-api-selecao-uniplus-standalone-...
# Confirmar:
#   - serviceAccountName=uniplus-api-selecao
#   - automountServiceAccountToken=true
#   - env UniPlus__Encryption__Provider=vault
#   - env UniPlus__Encryption__VaultAddress=http://platform-vault-uniplus-standalone.vault.svc.cluster.local:8200
#   - env UniPlus__Encryption__KubernetesRole=uniplus-api

sudo kubectl -n uniplus logs deploy/uniplus-api-selecao-uniplus-standalone-... | grep -i encryption
# Esperado: log inicial mostra Provider=vault sendo selecionado. Sem mensagens
# de fail-fast (CrashLoopBackOff indicaria validator/warmup bloqueando).
```

### 18.4 Rollback para Provider=local

Trocar `encryption.provider` de `vault` para `local` em `environments/standalone/values.yaml` para cada um dos 3 blocos `uniplusApi{Portal,Selecao,Ingresso}` **não basta** — o pod entrará em `CrashLoopBackOff` porque `EncryptionOptionsValidator` da uniplus-api (PR #401) exige `LocalKey` quando Provider=local.

Rollback completo é um PR separado, pois os charts atuais não têm wire-up de `UniPlus__Encryption__LocalKey` via Secret. Passos:

1. **Gerar e custodiar a chave**:

   ```bash
   head -c 32 /dev/urandom | base64
   # Custodiar em Vault: vault kv put secret/standalone/uniplus-api/encryption-local key=<gerada>
   ```

2. **No PR de rollback**:
   - Adicionar `ExternalSecret` (`apps/uniplus-api-*/templates/externalsecret.yaml`) materializando Secret K8s com key `LOCAL_KEY` a partir de `secret/standalone/uniplus-api/encryption-local`.
   - Adicionar env var no Deployment: `UniPlus__Encryption__LocalKey` referenciando o Secret via `secretKeyRef`.
   - Trocar `encryption.provider: vault` para `local` no environments/standalone/values.yaml + zerar `vaultAddress`/`kubernetesRole`.

3. **Aplicar via ArgoCD + verificar** que o pod não está mais consumindo Transit no audit log.

Em emergência (rollback de produção sem PR), aplicar manualmente os 2 recursos via `kubectl apply -f` e setar override `--set encryption.provider=local --set encryption.localKey=<chave>` na próxima sync do ArgoCD. **Avisar o time** porque a mudança vai ser sobrescrita pelo próximo `argocd sync` se não for committada.

### 18.5 Dependência da imagem

O fail-fast completo (validator + warmup hosted service) está nos PRs uniplus-api#401, #403, #406, #407 — mergeados nesta sessão. A próxima imagem GHCR publicada (provavelmente `v0.2.x` após cut da release) terá esses bits. Até lá, em produção standalone:

- Se a imagem atual NÃO tiver os bits do #400/#405, configurações inconsistentes ainda caem em "500 silencioso na primeira request cifrada" em vez de `CrashLoopBackOff`. O wire-up deste #220 funciona mesmo assim — apenas perde a defesa em profundidade.
- Para validar fail-fast completo, executar smoke #220 contra imagem nova quando publicada.

---

*Documento mantido pelo CTIC/UNIFESSPA. Atualizações via Pull Request.*
