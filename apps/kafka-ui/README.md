# kafka-ui (AKHQ)

Helm chart wrapper Uni+ para [AKHQ](https://github.com/tchiotludo/akhq), a interface web de consulta ao Apache Kafka do ambiente. Conecta-se ao broker por SASL_SSL com SCRAM-SHA-512, com um usuário próprio e ACLs mínimas, e autentica as pessoas pelo OIDC do Keycloak.

## Arquitetura

```text
Navegador (rede institucional ou VPN)
  └── HTTPS via Traefik IngressRoute (middleware adminInterno)
       └── AKHQ (namespace kafka-ui)
            ├── OIDC: client confidencial `kafka-ui` (segredo em keycloak/kafka-ui)
            ├── Kafka: usuário SCRAM `uniplus-kafka-ui-svc` (kafka/kafka-ui), nunca o `admin`
            ├── CA do broker: mesmo Secret, montado em /etc/akhq/certs/ca.crt
            └── SASL_SSL → broker da VM de infraestrutura, porta 9092
```

## Credencial no Kafka

O AKHQ usa o usuário `uniplus-kafka-ui-svc`, criado por `scripts/servicos-no-host/provisionar-kafka-ui.sh`, que guarda a senha só no Vault (`plataforma/kafka/kafka-ui`) e aplica as ACLs:

| Recurso | Operações | Para quê |
|---|---|---|
| cluster | `Describe`, `DescribeConfigs` | nós, configuração do broker, ACLs |
| tópicos (`*`) | `Describe`, `DescribeConfigs`, `Read` | lista, partições, offsets e mensagens |
| grupos de consumo (`*`) | `Describe` | grupos e atraso |
| `autorizacao_registros_de_acesso` | `Read` **negado** (`DENY`) | a trilha de acessos não é lida pela interface |

Não há `Write`, `Create`, `Delete` nem `Alter`: criar, apagar ou alterar tópicos continua com o `admin`, pelos scripts da VM de infraestrutura. No Kafka a negação prevalece sobre a permissão, então nenhuma ACL de leitura concedida depois reabre a trilha. O schema do chart recusa `kafka/admin` como `externalSecrets.kafkaCredencial.vaultPath`: o `admin` é superusuário do broker e passa por cima de todas as ACLs.

## Permissões: grupos do Keycloak → grupos do AKHQ

| Grupo do Keycloak | Grupo do AKHQ | O que vê |
|---|---|---|
| `/admins/kafka` | `admin` (embutido) | tudo o que a credencial do broker permite; as ações de escrita são recusadas pelo Kafka |
| `/users/kafka-ui-leitores` | `kafka-ui-leitores` | metadados de tópicos, grupos, nós e ACLs, e o conteúdo das mensagens, menos os tópicos de `topicosSemLeituraNaInterface` |
| qualquer outro, inclusive `/users/uniplus` | `no-roles` (embutido) | nada |

O grupo embutido `reader` do AKHQ não é usado: ele lê o conteúdo de todos os tópicos. A participação em `/users/kafka-ui-leitores` é individual, justificada e registrada (`docs/RUNBOOKS.md`, seção 9).

`topicosSemLeituraNaInterface` (padrão: `autorizacao_registros_de_acesso`; o schema exige que ele continue na lista) vira um padrão que exclui esses tópicos do papel de leitura de mensagens. É defesa em profundidade: o broker já nega a leitura à credencial do AKHQ.

## Pré-requisitos antes do sync

1. Client `kafka-ui` confidencial no realm, com o mapper `groups` exportando o caminho completo dos grupos.
2. `kafka/kafka-ui` no KV de plataforma, com `username`, `password` e `ca_cert` (`provisionar-kafka-ui.sh`).
3. `keycloak/kafka-ui` com o `client_secret` do client OIDC, e `kafka-ui/jwt` com `signing_secret` (`semear-vault.sh`).

Sem eles, os ExternalSecrets ficam em `SecretNotFound` e o pod em `CreateContainerConfigError`.

## Configuração mínima para habilitar

```yaml
kafkaUi:
  enabled: true
  kafka:
    bootstrapServers: <nome-do-host-de-dados>:9092
    sslEndpointIdentification: https
  oidc:
    issuerUri: https://<keycloak>/realms/<realm>
  ingress:
    enabled: true
    host: <host-do-kafka-ui>
  networkPolicy:
    dataHostCIDR: <ip-do-host-de-dados>/32
    oidcIssuerCIDR: <ip-do-issuer>/32
```

## Trade-offs e limitações

- **Stateless**: perder o pod não perde estado.
- **PKCE não suportado** em provedor OIDC customizado no AKHQ 0.27.x: o client é confidencial, com `client_secret` no Vault.
- **Auditoria das consultas feitas no AKHQ** não é enviada a um SIEM.

## Referências

- [Documentação do AKHQ](https://akhq.io/docs/)
- [Autorização e ACLs do Apache Kafka](https://kafka.apache.org/42/documentation.html#security_authz)
- ADR-009 — Kafka SASL_SSL + SCRAM-SHA-512
