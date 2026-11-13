# Runbook do Kafka UI

Procedimentos do Kafka UI (AKHQ) do ambiente `uniplus-prd` (e `uniplus-hml`, com `AMBIENTE=hml`): credencial própria no broker e concessão da leitura de conteúdo. O desenho está no `README.md` do chart `apps/kafka-ui`; a ordem geral de bootstrap e a renovação do certificado estão em [RUNBOOKS.md](RUNBOOKS.md), e os caminhos no Vault em [vault-caminhos.md](vault-caminhos.md).

O Kafka UI (AKHQ) nunca usa a credencial `admin` do Kafka: ela é super usuário e ignora ACLs. Ele entra com `uniplus-kafka-ui-svc`, que só descreve e lê, e que o broker proíbe de ler `autorizacao_registros_de_acesso`. O desenho está no `README.md` do chart `apps/kafka-ui`.

## 1. Provisionar e verificar a credencial

Na VM de infraestrutura, com o Vault aberto e o token em mãos (pedido sem eco), antes do primeiro sync do chart e depois do `provisionar-kafka.sh`:

```bash
./scripts/servicos-no-host/provisionar-kafka-ui.sh --dry-run
./scripts/servicos-no-host/provisionar-kafka-ui.sh provisionar
./scripts/servicos-no-host/provisionar-kafka-ui.sh verificar
```

`provisionar` é idempotente. Grava `username`, `password` e `ca_cert` em `plataforma/kafka/kafka-ui` (senha gerada uma vez e reaproveitada; CA regravado se mudou), aplica o usuário SCRAM e estas ACLs, todas literais:

| Recurso | Operações | Para quê |
|---|---|---|
| cluster | `Describe`, `DescribeConfigs` | nós, configuração do broker e ACLs |
| tópicos (`*`) | `Describe`, `DescribeConfigs` | listar tópicos, partições, offsets e configuração |
| tópicos (`*`) | `Read` | conteúdo das mensagens |
| grupos (`*`) | `Describe` | listar grupos e atraso |
| tópico `autorizacao_registros_de_acesso` | `Read` negado (`DENY`) | a negação prevalece no `StandardAuthorizer`: nenhuma ACL de leitura concedida depois reabre a trilha |

Não há `Write`, `Create`, `Delete` nem `Alter`; criar, apagar e alterar tópicos continua com `admin`. Também não há `Read` em grupo: a interface lê por atribuição manual de partição, sem grupo e sem confirmar offsets. `verificar` confere que as ACLs que alcançam o usuário (ou o curinga `User:*`) são exatamente essas e, com um tópico de teste que ele apaga ao fim, que o usuário lê outro tópico, descreve cluster, tópicos e grupos, e é recusado ao ler a trilha (com e sem grupo), gravar, criar e apagar tópico.

Depois do `provisionar`, o ExternalSecret da credencial sincroniza em até 1 hora (`refreshInterval`). O CA é montado por `subPath`, que não acompanha mudança do Secret, e a senha entra por variável de ambiente: depois do sync é preciso reiniciar o Deployment do Kafka UI, e só ele. Os nomes dos recursos dependem do release (no ArgoCD, o nome da Application, `kafka-ui`): o chart os nomeia `<release>-kafka-ui-...`. Conferir os reais antes de agir:

```bash
REL=kafka-ui
ES=externalsecret/$REL-kafka-ui-kafka-credentials
kubectl -n kafka-ui get deployment,externalsecret -l app.kubernetes.io/instance=$REL
# com release kafka-ui: Deployment kafka-ui-kafka-ui; ExternalSecret kafka-ui-kafka-ui-kafka-credentials
INICIO=$(date -u +%s)
kubectl -n kafka-ui annotate $ES force-sync=$INICIO --overwrite
# espera um sync posterior à anotação: o Ready de um sync anterior não basta
for _ in $(seq 60); do
  T=$(kubectl -n kafka-ui get $ES -o jsonpath='{.status.refreshTime}')
  [ -n "$T" ] && [ "$(date -u -d "$T" +%s)" -ge "$INICIO" ] && break
  sleep 2
done
kubectl -n kafka-ui wait $ES --for=condition=Ready --timeout=60s
kubectl -n kafka-ui rollout restart deployment/$REL-kafka-ui
```

Se o laço terminar sem sync posterior (`refreshTime` ainda anterior a `INICIO`), não reiniciar: ver `kubectl -n kafka-ui describe $ES`.

Nas versões anteriores do chart, o ExternalSecret da credencial do administrador era `<release>-kafka-ui-kafka-admin`. Se o ArgoCD não o podar, apagá-lo (`kubectl -n kafka-ui delete externalsecret/$REL-kafka-ui-kafka-admin`; o Secret gerado, de mesmo nome, vai junto), para que a credencial do administrador não fique no namespace.

Rotação: apagar `plataforma/kafka/kafka-ui` no Vault e rodar `provisionar` gera senha nova e a aplica no broker. Até o ExternalSecret sincronizar e o Deployment reiniciar, as novas conexões do Kafka UI falham a autenticação; por isso, em seguida, rodar os comandos acima (sync forçado, espera do sync posterior, `Ready`, reinício do Deployment), nessa ordem. O mesmo vale para o CA regravado por `renovar-certificado.sh`.

## 2. Conceder e revogar a leitura de conteúdo

Quem não está em `/admins/kafka` nem em `/users/kafka-ui-leitores` entra no Kafka UI sem nenhum papel, inclusive `/users/uniplus`. Ler o conteúdo das mensagens é concessão justificada do grupo `/users/kafka-ui-leitores`:

1. Quem administra o grupo registra, fora de repositório público, quem pede, o motivo e até quando.
2. Adiciona a pessoa ao grupo no Keycloak (no `uniplus-prd`, o realm é o do Keycloak institucional: só o grupo e a participação do Uni+, sem tocar em papéis, usuários ou configuração geral do realm; criar o grupo `/users/kafka-ui-leitores` no realm exige autorização explícita).
3. Ao fim do prazo, remove a pessoa do grupo. A sessão do AKHQ é um JWT próprio: a revogação vale quando a sessão atual expirar ou no próximo login.

Esse grupo nunca abre `autorizacao_registros_de_acesso`: o padrão do papel exclui os nomes de `kafkaUi.topicosSemLeituraNaInterface` e o broker nega a leitura à credencial. A consulta à trilha segue o procedimento da [ADR-018](adrs/ADR-018-retencao-e-acesso-aos-registros-de-acesso.md), não o Kafka UI.

## 3. Conferir o acesso depois de mudar grupos ou o chart

- Membro só de `/users/uniplus`: o login funciona, mas `GET /api/<cluster>/topic/<tópico>/data` não devolve mensagens (o AKHQ redireciona para `/ui/login`) e a tela mostra tópicos vazios.
- Membro de `/users/kafka-ui-leitores`: o tópico comum devolve mensagens; a trilha não aparece na lista e a leitura por nome é recusada.
- Membro de `/admins/kafka`: a leitura da trilha falha com `TopicAuthorizationException` vinda do broker.
