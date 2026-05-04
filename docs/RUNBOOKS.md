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

> ⚠️ **Bloqueado** até a Epic `data/*` estar implementada (Postgres, Kafka, MinIO, Redis via Docker Compose). Os volumes LVM já são provisionados pelo bootstrap; os containers precisam dos charts/compose em `data/`.

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

### 8.4 Init e verificação do Vault (OCI KMS auto-unseal)

> Procedimento detalhado a ser documentado em #87. Resumo:

O Vault standalone usa **OCI Vault KMS** para auto-unseal (diferente do lab, que usa Transit em PA1). O pod sobe selado e desvela automaticamente ao encontrar o KMS configurado.

```bash
# Verificar estado do Vault
kubectl exec -n vault vault-0 -- vault status

# Se Initialized=false, inicializar:
kubectl exec -n vault vault-0 -- vault operator init \
    -recovery-shares=5 -recovery-threshold=3
# Guardar recovery keys conforme procedimento institucional (Apêndice A)

# Validar auto-unseal ativo (Sealed=false sem intervenção manual):
kubectl exec -n vault vault-0 -- vault status | grep Sealed
# Esperado: Sealed          false
```

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

---

*Documento mantido pelo CTIC/UNIFESSPA. Atualizações via Pull Request.*
