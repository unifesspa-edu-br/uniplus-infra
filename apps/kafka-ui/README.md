# kafka-ui (AKHQ)

Helm chart wrapper Uni+ para [AKHQ](https://github.com/tchiotludo/akhq) — Web UI de gerenciamento do cluster Apache Kafka. Conecta ao broker SASL_SSL no `data-host` (ADR-009) via SCRAM-SHA-512; autentica usuários via OIDC do realm `uniplus` no Keycloak local.

## Status

Provisionado no ambiente de produção (issue #139, sub-issue de #40). Bloqueado por #138 (Kafka SASL_SSL hardening, mergeado em PR #140 + hotfix #141 — ADR-009).

## Arquitetura

```
Browser (admin Uni+)
  └── HTTPS via Traefik IngressRoute
       https://uniplus-kafka-ui.unifesspa.edu.br (ingress.host)
            └── AKHQ pod (apps/kafka-ui chart, namespace kafka-ui)
                 ├── OIDC client `kafka-ui` no realm de `oidc.issuerUri` (confidential)
                 ├── SCRAM próprio da interface via ESO (`kafka/kafka-ui`, só leitura no broker)
                 ├── CA cert PEM via projected volume (mesmo Secret ESO)
                 └── conexão SASL_SSL → kafka.bootstrapServers (uniplus-prod-infra.unifesspa.edu.br:9092)
```

## Permissões: grupos do Keycloak e credencial no broker

Duas camadas, e a do broker é a que vale.

**Interface.** Mapping no `application.yml` renderizado pelo chart:

| Grupo Keycloak | Grupo AKHQ | Capacidades |
|---|---|---|
| `/admins/kafka` | `admin` | criar/apagar tópicos, ver e gerir ACLs, alterar grupos de consumo e configuração; no broker, só o que as ACLs da credencial permitem |
| `/users/kafka-ui-leitores` | `leitor-de-conteudo` | listar e **ler o conteúdo** das mensagens, menos dos tópicos de `kafkaUi.topicosSemLeituraNaInterface` |
| (qualquer outro, inclusive `/users/uniplus`) | `no-roles` | nenhum acesso (default-group) |

O grupo `leitor-de-conteudo` reaproveita o papel `reader` do AKHQ com um padrão (regex Java, o recurso precisa casar com ao menos um padrão) que exclui os nomes listados: o AKHQ não tem negação, então o chart monta um lookahead negativo ancorado, com cada nome escapado como literal (`^(?!(?:a|b)$).*$`). O tópico excluído some da lista e a leitura dele pela API é recusada. Essa barreira é só da interface: o `DENY` no broker é aplicado apenas a `autorizacao_registros_de_acesso`, então outro nome acrescentado à lista exige a ACL correspondente em `provisionar-kafka-ui.sh`. A exclusão é por nome inteiro: `autorizacao_registros_de_acesso_x` seria legível. A concessão de `/users/kafka-ui-leitores` é justificada e registrada (procedimento em [`docs/RUNBOOK-KAFKA-UI.md`](../../docs/RUNBOOK-KAFKA-UI.md)).

**Broker.** O AKHQ usa a credencial SCRAM `uniplus-kafka-ui-svc`, criada por `scripts/servicos-no-host/provisionar-kafka-ui.sh` e guardada em `plataforma/kafka/kafka-ui` (chaves `username`, `password`, `ca_cert`). O schema recusa `kafka/admin` como caminho: o administrador é super usuário e ignora ACLs. As ACLs são mínimas e literais: `Describe` e `DescribeConfigs` no cluster e em todos os tópicos, `Describe` em todos os grupos, `Read` em todos os tópicos e `DENY` de `Read` em `autorizacao_registros_de_acesso`. Nada de `Write`, `Create`, `Delete` nem `Alter`: criar, apagar e alterar continua com a credencial `admin`, pelos scripts da VM de infraestrutura. Mesmo um membro de `/admins/kafka` não lê a trilha de acessos pela interface: quem recusa é o broker.

A leitura de mensagens usa atribuição manual de partição, sem grupo e sem confirmar offsets (`group.id` não é definido e `enable.auto.commit` é `false` nos padrões do AKHQ 0.27); por isso não há `Read` em grupo de consumo.

## Pré-requisitos antes do ArgoCD sync

1. **Realm com o client `kafka-ui` confidential** e o mapper `groups` (caminho completo) exportando a participação em grupos no claim `groups` do JWT; grupos `/admins/kafka` e `/users/kafka-ui-leitores` criados
2. **`kafka/kafka-ui` em Vault** (KV `plataforma-<amb>`), criado por `provisionar-kafka-ui.sh` na VM de infraestrutura: chaves `username`, `password`, `ca_cert`
3. **`keycloak/kafka-ui` em Vault** com `client_secret` do client OIDC (custódia manual via `vault kv put`)
4. **`kafka-ui/jwt` em Vault** com `signing_secret`: sem ele o AKHQ aplica os grupos só na interface, não na API

Sem esses, os ExternalSecrets ficam em `SecretNotFound` e o pod entra em `CreateContainerConfigError`.

## Configuração mínima para habilitar

Em `environments/uniplus-prd/values.yaml`:

```yaml
kafkaUi:
  enabled: true
  kafka:
    bootstrapServers: 10.0.2.87:9092
  oidc:
    issuerUri: https://uniplus.unifesspa.edu.br/auth/realms/uniplus
  ingress:
    enabled: true
    host: uniplus.unifesspa.edu.br
    tls:
      certManager:
        enabled: true
        clusterIssuer: letsencrypt-staging
  networkPolicy:
    dataHostCIDR: 10.0.2.0/24
```

## Operações comuns

Procedimentos:

- [`docs/RUNBOOK-KAFKA-UI.md`](../../docs/RUNBOOK-KAFKA-UI.md): credencial do Kafka UI no broker (provisionar e verificar) e concessão do grupo `/users/kafka-ui-leitores`
- [`docs/RUNBOOKS.md`](../../docs/RUNBOOKS.md), seção 4: renovação do certificado (regrava o CA também em `plataforma/kafka/kafka-ui`)

## Trade-offs e limitações

- **AKHQ é stateless** — perda de pod sem impacto em state (estado vive no Kafka).
- **OIDC PKCE não suportado em provider customizado em 0.27.x** — usamos confidential client com `client_secret` em Vault. AKHQ é backend (não SPA), então confidential é correto arquiteturalmente.
- **Audit log de operações no AKHQ → SIEM** ainda não integrado (futuro hardening).
- **Multi-cluster** desligado — só o Kafka do ambiente.

## Referências

- [AKHQ docs](https://akhq.io/docs/)
- [Apache Kafka 4.2 docs](https://kafka.apache.org/42/documentation.html)
- ADR-009 — Kafka SASL_SSL + SCRAM-SHA-512
- Issue #139 — escopo deste chart
