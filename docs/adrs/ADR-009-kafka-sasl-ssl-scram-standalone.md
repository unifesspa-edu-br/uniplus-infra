# ADR-009: Kafka standalone com SASL_SSL + SCRAM-SHA-512 + StandardAuthorizer

- **Status:** 🟡 Proposta
- **Data:** 2026-05-07
- **Relacionado:** [Issue #138](https://github.com/unifesspa-edu-br/uniplus-infra/issues/138) · [Story #118 (fechada)](https://github.com/unifesspa-edu-br/uniplus-infra/issues/118) · [Epic #40](https://github.com/unifesspa-edu-br/uniplus-infra/issues/40) · [ADR-005](ADR-005-stateful-em-containers-via-systemd.md) · [ADR-008](ADR-008-topologia-standalone.md)

## Contexto

A Story #118 entregou Kafka 4.2.0 KRaft (PR #137) em **PLAINTEXT** sem autenticação. Defesa baseada apenas em segregação de rede: subnet privada VCN do OCI + iptables INPUT chain filtrando externos. Aceitável para validação inicial pelas razões originais:

1. Standalone é monolocal, não modela resiliência (ADR-008)
2. Sem apps consumidoras ainda — Fase 5 ainda não entregou imagens GHCR
3. PR #137 já era complexo (KRaft format, listener config, idempotência) — adicionar SASL_SSL no mesmo PR teria explodido em rounds Codex

Com a Fase 5 se aproximando, o débito técnico ficou explícito:

- **Apps reais (uniplus-portal, uniplus-api-selecao, etc.) precisam de auth** — produzir/consumir tópicos sem credentials viola o pattern dos demais services (Postgres, Redis, MinIO usam password auth via Vault/ESO).
- **Promoção a hml/prod requer auth + cifra** — adiar significa refactor maior depois, com apps já dependendo do contrato PLAINTEXT.
- **Compliance LGPD** — eventos publicados podem conter PII (CPF, nome social do candidato). Cleartext intra-VCN ainda é cleartext: snapshots do data-host, logs verbose de aplicação, captura de pacotes em troubleshooting podem expor dados regulados.
- **Princípio "produção desde o início"** — apps consomem o pattern seguro desde o primeiro PR de Fase 5; nada de "depois a gente endurece".

## Alternativas consideradas

### 1. Manter PLAINTEXT, hardenar só na promoção a hml

- ❌ Rejeitada. Refactor depois é mais caro: apps Fase 5 já implementadas com `security.protocol=PLAINTEXT` precisariam atualizar config + redeployar; cada app cliente vira um ponto de falha de migração; ADRs e RUNBOOKS ficam dessincronizados entre standalone e hml.

### 2. SASL/SCRAM-SHA-512 sobre PLAINTEXT (`SASL_PLAINTEXT`)

- ❌ Rejeitada. Auth sem cifra: a senha SCRAM **em si** não trafega (SCRAM faz challenge-response com salted hash), mas o **payload das mensagens** trafega em clear — exatamente o que LGPD pede pra cifrar. Ganho parcial não justifica complexidade igual ao SASL_SSL.

### 3. mTLS puro (`SSL` com `ssl.client.auth=required`)

- ❌ Rejeitada para MVP. Auth via client certificate tem propriedades superiores (zero-trust, sem shared secrets em Vault), mas:
  - **Lifecycle de certs por aplicação** — cada app precisa cert provisionado via cert-manager + CSR via SPIFFE/SPIRE ou via injection sidecar; complexidade alta
  - **Rotação automática** demanda cert-manager-csi-driver-spiffe ou equivalente — exagero pra MVP single-host
  - Mantemos como **caminho de evolução** quando 3-DC + apps maduras justificarem

### 4. SASL/OAUTHBEARER (JWT do Keycloak)

- ❌ Rejeitada para MVP. Atrativo arquiteturalmente — unifica AuthN com o resto da stack via realm `uniplus`. Mas:
  - **Kafka 4.x OAUTHBEARER ainda exige config customizada** (`org.apache.kafka.common.security.oauthbearer.OAuthBearerLoginCallbackHandler` próprio) — não é plug-and-play como SCRAM
  - **Validação de JWT no broker** demanda library customizada ou JWKS endpoint config; menos rodado em single-node
  - Aplicações .NET 10 / Angular 21 não consomem Kafka diretamente do browser — backend é o único cliente; SCRAM password em Vault é tão seguro quanto JWT do mesmo backend
  - Mantemos como **caminho de evolução** quando schema registry, audit logs e MIM federada justificarem

### 5. SASL_SSL + SCRAM-SHA-512 + StandardAuthorizer ⭐

- ✅ **Escolhida.**
- Auth: SCRAM-SHA-512 — challenge-response com salted hash, NIST-aprovado, sem rainbow tables
- Cifra: TLS 1.2/1.3 — protege payload em wire
- Authorization: `StandardAuthorizer` (KRaft-native, substitui o `AclAuthorizer` da era ZK), com `ALLOW_EVERYONE_IF_NO_ACL_FOUND=false` — fail-closed
- Pattern alinhado com Postgres/Redis/MinIO (password auth via Vault → ESO → app)
- Apps Fase 5 consomem o modelo seguro **desde o primeiro PR**

## Decisão

Migrar Kafka standalone para **SASL_SSL + SCRAM-SHA-512 + StandardAuthorizer**, com as seguintes premissas:

### Encryption (TLS)

| Item | Standalone | hml/prod (futuro) |
|---|---|---|
| Geração de cert | Self-signed estático via `openssl req` no bootstrap (validade 10 anos, regenerado só se ausente) | cert-manager Issuer (interno ou Let's Encrypt) com rotação automática + sync para o broker via secret-sync |
| Formato | PEM (`KAFKA_SSL_KEYSTORE_TYPE=PEM`) — Kafka 3.0+ aceita PEM nativo; sem conversão para JKS | Idem |
| CA | Self-signed = CA = cert (cadeia de 1 nível) | Cadeia real (Let's Encrypt root → intermediate → cert) |
| Path no host | `/etc/uniplus-kafka/certs/{server.crt,server.key,ca.crt}` (root:root, key 600, crt 644) | Idem, mas populado via cron-sync de cert-manager |
| Validade | 10 anos (validação intencional) | 90 dias com rotação automática |

**Por que self-signed estático em standalone:** Kafka roda como container Docker via systemd no `data-host`, **fora do cluster K8s** (ADR-005). cert-manager é uma extensão K8s e **não atinge o data-host nativamente**. Para hml/prod, padrão será cert-manager + secret-sync (job no K8s exporta o cert renovado para um path acessível ao data-host via SSH ou volume compartilhado). Implementar esse pipeline em standalone, com 1 broker e 0 apps consumindo, é overengineering. Self-signed estático com validade longa cobre toda a janela de validação.

### Authentication (SASL/SCRAM-SHA-512)

| Item | Detalhe |
|---|---|
| Mecanismo | `SCRAM-SHA-512` exclusivamente (`SCRAM-SHA-256` legado não é habilitado) |
| Admin user | `admin`, password 32 bytes hex (`openssl rand -hex 32`), embarcada via `kafka-storage.sh format --add-scram "SCRAM-SHA-512=[name=admin,password=<PW>]"` no bootstrap inicial |
| Inter-broker | Mesmo `admin` user (single-node combined) — config via `listener.name.<NAME>.scram-sha-512.sasl.jaas.config` |
| Per-app users | Criados na Fase 5 via `kafka-configs.sh --alter --add-config 'SCRAM-SHA-512=[password=...]' --entity-type users --entity-name <app>-svc`. Custódia em `secret/standalone/kafka/<app>-svc` (ESO sintetiza secret K8s) |
| Custódia | `secret/standalone/kafka/admin` no Vault: `username`, `password`, `mechanism=SCRAM-SHA-512`, `bootstrap_servers`, `ca_cert` (PEM da CA) |

### Authorization (ACLs via StandardAuthorizer)

| Item | Detalhe |
|---|---|
| Implementação | `org.apache.kafka.metadata.authorizer.StandardAuthorizer` (KRaft-native; substitui `kafka.security.authorizer.AclAuthorizer` da era ZK) |
| Default | `allow.everyone.if.no.acl.found=false` — **fail-closed**. Apps sem ACL explícita são negadas |
| Super users | `super.users=User:admin` — admin tem permissão total sem ACLs |
| Pattern por app | ACL prefixed pra topics e consumer groups; sem wildcards globais |

Exemplo de ACL pattern (Fase 5):

```bash
# uniplus-portal-svc pode produzir e consumir em uniplus.events.*
kafka-acls.sh --bootstrap-server kafka.standalone.portaluni.com.br:9092 \
  --command-config /etc/kafka/admin.properties \
  --add --allow-principal User:uniplus-portal-svc \
  --producer --topic 'uniplus.events.' --resource-pattern-type prefixed

kafka-acls.sh --bootstrap-server kafka.standalone.portaluni.com.br:9092 \
  --command-config /etc/kafka/admin.properties \
  --add --allow-principal User:uniplus-portal-svc \
  --consumer --topic 'uniplus.events.' --resource-pattern-type prefixed \
  --group 'uniplus-portal.'
```

### Listener configuration

```
KAFKA_LISTENERS=SASL_SSL://10.0.2.87:9092,CONTROLLER://10.0.2.87:9093
KAFKA_ADVERTISED_LISTENERS=SASL_SSL://10.0.2.87:9092
KAFKA_INTER_BROKER_LISTENER_NAME=SASL_SSL
KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER
KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:SASL_SSL,SASL_SSL:SASL_SSL
KAFKA_SASL_ENABLED_MECHANISMS=SCRAM-SHA-512
KAFKA_SASL_MECHANISM_INTER_BROKER_PROTOCOL=SCRAM-SHA-512
KAFKA_SASL_MECHANISM_CONTROLLER_PROTOCOL=SCRAM-SHA-512
```

> Nota: o `advertised.listeners` continua usando IP `10.0.2.87` em vez de hostname pelo cert ter SAN cobrindo IP + DNS via `subjectAltName`. Self-signed gerado com ambos os SANs.

## Justificativa

A escolha por SASL_SSL + SCRAM se sustenta em três eixos:

1. **Pattern padrão da stack Uni+** — Postgres, Redis, MinIO já usam password auth com TLS terminal (no caso do Postgres/Redis/MinIO em standalone PLAINTEXT, mas TLS é o pattern de produção quando promovem). Kafka adotando o mesmo modelo simplifica o mental model dos devs e reusa o procedimento operacional (custódia em Vault, ESO sintetiza secret K8s, app consome via env).
2. **`StandardAuthorizer` é KRaft-native** — desde Kafka 3.3 GA, é a implementação canônica para clusters KRaft. `AclAuthorizer` (era ZK) está deprecated em 4.x; usar `StandardAuthorizer` é decisão de presente, não débito.
3. **Migração futura para mTLS ou OAUTHBEARER é aditiva**, não destrutiva — basta adicionar listener novo (`MTLS://...:9094`) ou config OAUTHBEARER em paralelo ao SASL_SSL existente. Apps continuam funcionando enquanto a migração roda.

## Consequências

### Positivas

- Apps Fase 5 já chegam com auth+cifra desde o primeiro PR (sem refactor de migração)
- Compliance LGPD endereçada (cifra em wire)
- Pattern alinhado a hml/prod (mesmo modelo, só muda CA self-signed → CA institucional)
- ACLs fail-closed previnem expansão acidental de privilégio (e.g., dev cria topic novo sem ACL, app não consegue produzir → erro óbvio em vez de comportamento aleatório)
- Custódia em Vault unifica gestão de secrets de todos os data services

### Negativas

- Bootstrap mais complexo: passa a ter cert + SCRAM + ACLs além do que tinha; aumenta superfície de erro inicial
- Self-signed gera browser warning quando AKHQ (Web UI, #139) tentar conectar — mitigado distribuindo o CA via configmap
- `kafka-broker-api-versions.sh` e demais ferramentas precisam de `--command-config` apontando pro client.properties — mais ergonômico esquecer flag e ver `Authorization failed`
- Rotação de admin password vira operação não-trivial (precisa ALTER user no Kafka + atualizar Vault + reiniciar broker para refresh do JAAS) — documentar em runbook §13.6 atualizado
- `super.users=User:admin` em hml/prod precisa virar role-based (admin ops vs admin platform) — débito documentado para Story HA

### Neutras

- Self-signed estático com validade 10 anos significa **sem rotação** durante a vida do standalone — aceitável porque o cert nunca trafega externamente (subnet privada VCN). Quando promover, cert-manager assume.
- `cluster_id` continua sendo identificador, não segredo — registro em Vault é só auditoria (já implementado em PR #137; ADR mantém)

## Caminho de migração

1. **Este ADR** — formaliza a decisão
2. **PR refator `step_data_setup_kafka`** — bootstrap script gera cert self-signed + SCRAM + StandardAuthorizer + custódia
3. **RUNBOOKS §13 atualizado** — operações reflectindo SASL_SSL (cliente properties, criar user per-app, rotação admin, troubleshooting cert/ACL)
4. **Issue #139 (AKHQ)** — Web UI consome SCRAM admin via ESO + CA via configmap
5. **Fase 5 (apps reais)** — cada app tem sua Story criando user SCRAM + ACLs prefixed
6. **Story HA futura** — migrar self-signed → cert-manager com secret-sync para data-host; introduzir mTLS opcionalmente
