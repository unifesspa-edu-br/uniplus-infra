# ADR-018: Retenção e controle de acesso aos registros de acesso

- **Status:** 🟡 Proposto (depende das decisões pendentes listadas abaixo)
- **Data:** 2026-11-12
- **Issue:** [#798](https://github.com/unifesspa-edu-br/uniplus-infra/issues/798)
- **Relacionado:** [ADR-009](ADR-009-kafka-sasl-ssl-scram.md) · [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md) · [ADR-017](ADR-017-producao-aplicada-pelo-pipeline-na-vm-de-automacao.md) · ADR-0153 e ADR-0162 da `uniplus-api` · [uniplus-api#2371](https://github.com/unifesspa-edu-br/uniplus-api/issues/2371) · épica [uniplus-api#2373](https://github.com/unifesspa-edu-br/uniplus-api/issues/2373) · UNI-REQ-0203 e UNI-REQ-0379

## Contexto

A API registra, antes de entregar o dado, todo acesso de servidor a dado pessoal ou sensível de candidato e toda recusa (UNI-REQ-0203). O registro vai a um tópico Kafka próprio, fora da base da aplicação, e a falha de publicação recusa a leitura ([ADR-0153 da `uniplus-api`](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0153-projecao-por-protecao.md)). A [ADR-0162 da `uniplus-api`](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0162-separacao-das-atribuicoes-de-governanca.md) deixou retenção, controle de acesso e consulta desses registros para um incremento de prioridade baixa. Esta ADR registra o estado atual, conferido só pelo que está nos repositórios, e propõe a política. Os values de `environments/uniplus-prd/` são values de validação dos charts no CI ([README](../../README.md)), e não a produção implantada, que vem do repositório de implantação ([ADR-016](ADR-016-producao-le-o-repositorio-de-implantacao.md)). Por isso **não foram verificados** a configuração implantada do tópico, as ACLs efetivas no broker, os membros dos grupos do Keycloak, a existência de backup e o uso efetivo das credenciais; essa conferência é somente leitura e cabe ao repositório de implantação.

## Estado atual

### Tópico, retenção e partições

O tópico `autorizacao_registros_de_acesso` não é declarado por chart nem por recurso do Kubernetes (não há Strimzi: o Kafka roda fora do cluster, em systemd, pela [ADR-005](ADR-005-stateful-em-containers-via-systemd.md)). Ele é criado por script, na VM de infraestrutura:

- `scripts/servicos-no-host/provisionar-kafka.sh:43-44`: tópico com 3 partições.
- `scripts/servicos-no-host/provisionar-kafka.sh:174-184`: fator de replicação 1 (nó único), `retention.ms=-1` e `cleanup.policy=delete`, reaplicados a cada execução. **A retenção hoje é ilimitada**, e o limite por tamanho (`retention.bytes`) não é definido no tópico, valendo o padrão do broker.
- O produtor confirma com `acks=all` e idempotência (`uniplus-api`, `src/shared/Unifesspa.UniPlus.Infrastructure.Core/Authorization/RegistroDeAcessoKafkaOptions.cs:54-56`). Com um nó só, `acks=all` equivale a uma réplica: a trilha não tem cópia em outro nó. Nenhum backup do tópico está descrito neste repositório; se existe no ambiente, não foi verificado.

### Quem escreve

- Usuário SCRAM `uniplus-api-registro-acesso-svc`, com ACL literal só de `Write` e `Describe` no tópico (`scripts/servicos-no-host/provisionar-kafka.sh:42`, `:186-199`); o subcomando `verificar` prova que a conta não lê nem cria tópico (`:216-246`, `:292-344`).
- Senha no Vault em `kafka/uniplus-api-registro-acesso-svc` do KV do Uni+ (`docs/vault-caminhos.md:67`), entregue ao pod pelo ExternalSecret (`apps/uniplus-api-host/templates/externalsecret.yaml:165`, `apps/uniplus-api-host/values.yaml:385`).
- O chart `uniplus-api-host` tem o bloco desligado por padrão (`apps/uniplus-api-host/values.yaml:201-202`) e os values de validação de produção o ligam (`environments/uniplus-prd/values.yaml:211-214`); a ativação no ambiente implantado não foi verificada.

### Quem lê

- **Nenhum consumidor de aplicação existe.** O serviço de armazenamento consultável previsto na ADR-0153 da `uniplus-api` ainda não foi desenhado; nenhuma ACL de `Read` foi concedida a usuário de aplicação.
- O broker nega o que não tem ACL (`allow.everyone.if.no.acl.found=false`) e tem `super.users=User:admin` (`scripts/servicos-no-host/instalar-kafka.sh:295-296`; [ADR-009](ADR-009-kafka-sasl-ssl-scram.md)). Quem tem a credencial `admin` lê, altera a retenção e apaga registros do tópico; o próprio `verificar` usa o `admin` para remover a mensagem de teste (`scripts/servicos-no-host/provisionar-kafka.sh:390-397`).
- **O Kafka UI (AKHQ) conecta como `admin`** (`apps/kafka-ui/files/application.yml.tpl:14`, `apps/kafka-ui/values.yaml:83-84`) e mapeia o grupo `/users/uniplus` do Keycloak para o papel `reader` e `/admins/kafka` para `admin` (`apps/kafka-ui/values.yaml:66-68`, `apps/kafka-ui/files/application.yml.tpl:60-66`). Os values de validação de produção ligam o Kafka UI sem sobrescrever esse mapeamento (`environments/uniplus-prd/values.yaml:630-643`) e limitam a interface pela middleware `uniplus-admin-interno` (`:644-646`). Se a configuração implantada for a mesma, quem está nesses grupos vê o conteúdo do tópico pela interface, sem registro dessa leitura no Uni+. A configuração implantada e os membros dos grupos não foram verificados.
- A credencial `admin` também está no Vault em `kafka/admin`, nos KVs `uniplus-<amb>` e `plataforma-<amb>` (`docs/vault-caminhos.md:69`), e é referenciada pelo transporte do Wolverine nos charts `uniplus-api-host` e `uniplus-api-portal` (`apps/uniplus-api-host/values.yaml:376-377`, `apps/uniplus-api-portal/values.yaml:158-159`), desligado para o portal nos values de validação de produção (`environments/uniplus-prd/values.yaml:337-338`). O uso efetivo dessa credencial no ambiente não foi verificado.

### Conteúdo da mensagem

Na `uniplus-api`, a chave da mensagem é o identificador da execução e o valor é um lote JSON de registros, cada um com sua chave SHA-256 (`src/shared/Unifesspa.UniPlus.Infrastructure.Core/Authorization/RegistroDeAcessoKafka.cs:78-84`, `:113`, `:220`), com schema em `contracts/kafka/registro-de-acesso/v1.schema.json`. Cada registro (`src/shared/Unifesspa.UniPlus.Authorization/Contracts/RegistroDecisaoAcesso.cs:32-123`) traz instante, emissor e `subject` do token de quem acessou, `RequestId`, permissão, tipo e identificadores do resource (unidade, processo, chamada, resource, inscrição), código do fato revelado e ocorrência, sensibilidade efetiva, origem, client OIDC, resultado, motivo da negativa e a concessão usada. Os cabeçalhos não levam dado do ator nem do resource (`src/shared/Unifesspa.UniPlus.Infrastructure.Core/Authorization/CabecalhosDoRegistroDeAcesso.cs:13-60`).

**Não há conteúdo do dado acessado**, mas há dado pessoal:

- o `subject` do token identifica o servidor que acessou (pseudônimo, reidentificável pelo provedor de identidade);
- o identificador da inscrição identifica o candidato indiretamente;
- o código do fato com a sensibilidade `sensivel` revela que o candidato tem um dado de categoria sensível (por exemplo, um laudo de deficiência ou a autodeclaração étnico-racial), o que pode bastar para inferir a informação sensível (LGPD, art. 5º, II, e art. 11).

## Decisão proposta

### Retenção

1. **O tópico é transporte, e não o arquivo da trilha.** Com o serviço de consulta em operação, o tópico passa a ter retenção finita, longa o bastante para o consumidor se recuperar de uma parada sem perda. Proposta: 30 dias por tempo.
2. **Capacidade dimensionada por partição.** Um limite por tamanho (`retention.bytes`, que vale por partição) pode apagar registros ainda não consumidos antes dos 30 dias. Por isso ele só é definido se a capacidade de cada partição comportar o volume esperado do período de recuperação, com folga; caso contrário, fica sem limite por tamanho e o disco é protegido por alerta. Entram com a mudança dois alertas: de capacidade (disco da VM de dados e tamanho de cada partição em relação ao limite) e de atraso de consumo (lag do grupo do serviço de consulta, com limiar bem abaixo do período de retenção).
3. **Até o serviço existir, a retenção continua ilimitada.** O tópico é hoje o único lugar onde a trilha existe; encurtá-la antes de haver um armazenamento durável apagaria registros sem cópia. A retenção só é reduzida quando, cumulativamente:
   - o serviço de consulta persiste os registros de forma durável, com backup próprio;
   - para cada partição, há reconciliação entre o tópico e o armazenamento até o offset de corte (todo registro abaixo do offset está persistido, conferido pela chave SHA-256 de cada registro);
   - a recuperação do armazenamento a partir do backup foi testada e o resultado registrado.
4. **O prazo da trilha vale no armazenamento consultável.** Proposta: 5 anos a contar do acesso, apagados ao fim do prazo. O fundamento a confirmar pela Procuradoria é o prazo de prescrição da ação punitiva da administração pública federal (Lei nº 9.873/1999, art. 1º) e o da ação disciplinar (Lei nº 8.112/1990, art. 142), sem afirmar que bastem para justificar o prazo. Como comparação apenas: o Marco Civil da Internet (Lei nº 12.965/2014, art. 15) obriga o provedor de aplicações de internet constituído como pessoa jurídica, que exerça a atividade de forma organizada, profissional e com fins econômicos, a guardar os registros de acesso a aplicações por 6 meses, sob sigilo e em ambiente controlado e de segurança. A universidade não se enquadra nessas condições, e os 6 meses não são piso nem teto aqui. O prazo precisa ser finito e justificado pela necessidade (LGPD, art. 6º, III).

### Transição da retenção

O `provisionar-kafka.sh` reaplica `retention.ms=-1` a cada execução (`scripts/servicos-no-host/provisionar-kafka.sh:174-184`); sem mudança, uma nova execução desfaria a retenção aprovada. A transição inclui, em issue própria, mudar o script para aplicar os valores aprovados de `retention.ms` (e de `retention.bytes`, se houver) e para falhar, no provisionamento e no `verificar`, quando a configuração do tópico divergir deles. Esta ADR só descreve a mudança; o script não foi alterado.

### Controle de acesso

1. **Produtor só escreve.** Mantém-se a ACL literal de `Write` e `Describe` de `uniplus-api-registro-acesso-svc`, sem `Read`, `Create`, `Alter` nem `Delete`.
2. **Leitura só pelo serviço de consulta.** O serviço ganha usuário SCRAM próprio, com ACL literal de `Read` e `Describe` no tópico e `Read` num grupo de consumidores de nome literal, e nada mais. Nenhuma outra conta de aplicação recebe `Read`.
3. **Objetivo pendente: retirar a leitura do conteúdo pelo Kafka UI.** A restrição do AKHQ (filtro de tópico por grupo ou exclusão do tópico da conexão) é meio, e não prova que a lacuna foi fechada. O objetivo só se considera atingido com um controle verificável:
   - na interface, testes negativos por papel (`reader` e `admin` do AKHQ) mostrando que nenhum dos dois exibe mensagens do tópico, com a evidência anexada;
   - na API, testes negativos por papel mostrando que só a permissão de consulta da auditoria alcança os registros, e só os metadados;
   - enquanto o AKHQ conectar como `admin`, a restrição depende da configuração da interface e não do broker; a alternativa de usuário SCRAM próprio para o AKHQ, sem `Read` neste tópico, fica para avaliação.
4. **Uso individualizado e auditável do `admin`.** Alterar a configuração do tópico, apagar registros ou ler o conteúdo em exceção exige o `admin`. O uso fica restrito aos scripts de provisionamento e a um procedimento documentado no runbook que registre quem usou, quando, com que finalidade e qual comando, com a retirada da senha no Vault vinculada a essa pessoa (a auditoria do Vault registra a leitura do caminho). Desenhar e testar esse procedimento é pendente.

### Consulta

1. **Somente metadados.** A consulta devolve quem acessou, quando, com que permissão, de qual inscrição e qual fato, nunca o conteúdo do dado (UNI-REQ-0203; [uniplus-api#2371](https://github.com/unifesspa-edu-br/uniplus-api/issues/2371)).
2. **Finalidade declarada.** A consulta serve à fiscalização pela proteção de dados (atribuída ao Encarregado de dados no desenho proposto pela ADR-0162 da `uniplus-api`, ainda com status proposto), à apuração de incidente de segurança e ao atendimento de requisição do titular sobre o tratamento dos seus dados (LGPD, art. 18, I e II, confirmação e acesso), conforme a proteção de dados definir.
3. **Permissão `Sensível`.** Pela regra do maior nível, o registro de acesso a dado sensível é ele próprio sensível; a consulta exige concessão de sensibilidade `sensivel`.
4. **Consulta registrada.** Toda consulta, inclusive listagem, gera registro de acesso pelo mesmo mecanismo da UNI-REQ-0203, e a falha do registro recusa a consulta.

### Base legal para dados sensíveis

A hipótese a validar, por finalidade e por categoria de dado, é a do cumprimento de obrigação legal ou regulatória pelo controlador (LGPD, art. 7º, II; para o dado sensível que o registro permite inferir, art. 11, II, "a"), no exercício da competência legal da universidade (art. 23). A hipótese não é demonstrada só pelos arts. 37 e 46, e eles não fixam prazo; é preciso distinguir três coisas:

- **inventário das operações de tratamento** (art. 37): o controlador mantém registro das operações que realiza, o que não exige, por si, guardar cada evento de acesso indefinidamente;
- **trilha técnica de acesso**: o registro de cada acesso, que é o objeto desta ADR, cuja necessidade e prazo dependem da finalidade (apuração de acesso indevido, responsabilização, atendimento ao titular) e precisam ser justificados para cada uma;
- **medidas de segurança** (art. 46): a trilha é uma medida técnica entre outras, e o art. 46 pede medidas aptas a proteger os dados, sem determinar quais registros guardar nem por quanto tempo.

A validação cabe à proteção de dados, com a Procuradoria se necessário, e é uma das razões de esta ADR ser uma proposta.

## Decisões pendentes

Nenhum destes pontos está aprovado; cada um depende de quem o decide.

| Ponto | Proposta | Quem decide |
|---|---|---|
| Prazo da trilha no armazenamento consultável | 5 anos, apagados ao fim | proteção de dados, com a unidade de gestão documental |
| Base legal do tratamento dos registros, inclusive dos sensíveis | hipótese do art. 7º, II, e art. 11, II, "a", com art. 23, a validar por finalidade e categoria de dado | proteção de dados, com a Procuradoria se necessário |
| Finalidades admitidas da consulta | fiscalização, incidente, requisição do titular (art. 18, I e II) | proteção de dados |
| Retenção do tópico após o consumidor | 30 dias; limite por tamanho só se a capacidade por partição comportar o período; alertas de capacidade e de atraso de consumo; redução só após persistência durável, reconciliação por partição e recuperação testada | infraestrutura |
| Restrição do Kafka UI sobre o tópico | objetivo de nenhum papel do AKHQ ler o conteúdo, comprovado por testes negativos por papel na interface e na API | infraestrutura, ouvida a proteção de dados |
| Durabilidade da trilha enquanto o tópico é o único armazenamento (nó único; backup não verificado) | conferir o ambiente; se não houver, backup periódico do tópico ou replicação | infraestrutura |
| Mudança do `provisionar-kafka.sh` para aplicar a retenção aprovada e falhar na divergência | issue própria neste repositório | infraestrutura |
| Procedimento individualizado e auditável de uso do `admin` | runbook com registro de quem, quando, finalidade e comando | infraestrutura, ouvida a proteção de dados |
| Cifra em repouso do volume do Kafka | a conferir no repositório de implantação | infraestrutura |
| Desenho do serviço de consulta (base, schema, apagamento por prazo) | ADR própria na `uniplus-api` | arquitetura |

## Consulta à auditoria não atendida

**A consulta aos registros de acesso não está atendida.** Os registros são enviados e guardados no tópico, mas ninguém os consulta pelo Uni+, como diz a UNI-REQ-0379 (incremento planejado, de prioridade baixa). A implementação é [uniplus-api#2371](https://github.com/unifesspa-edu-br/uniplus-api/issues/2371), que depende desta decisão, do desenho do serviço, da permissão `Sensível` e das decisões pendentes acima. Até lá, a resposta a "quem acessou este dado" depende de extração operacional com a credencial `admin`, que deve ser feita por procedimento documentado e com a finalidade registrada.

## Repositório de implantação

O que esta ADR não faz e cabe ao repositório de implantação (GitLab), com referência cruzada para a issue #798:

- conferir, somente leitura, a configuração do tópico em produção (`retention.ms`, `retention.bytes`, partições) e as ACLs efetivas, e anexar a evidência à #798;
- conferir se os values de produção do Kafka UI sobrescrevem o mapeamento de grupos e se os grupos `/users/uniplus` e `/admins/kafka` têm membros;
- conferir se existe backup do volume do Kafka e se o envio dos registros está ligado no ambiente;
- aplicar a nova retenção do tópico e a restrição do Kafka UI quando as decisões pendentes forem aprovadas.

## Consequências

- **Riscos identificados**, com aceitação ou mitigação pendente da autoridade responsável (infraestrutura, ouvida a proteção de dados):
  - enquanto não houver consumidor, a trilha cresce sem limite numa réplica só, com risco de esgotar o disco da VM de dados;
  - a perda do volume perde a trilha, se a conferência do ambiente confirmar que não há backup do tópico;
  - se a configuração implantada do Kafka UI for a dos values de validação, a leitura do conteúdo pela interface escapa ao registro de acesso. A restrição proposta é um objetivo, e a lacuna só se considera fechada com os testes negativos descritos em Controle de acesso.
- Quem tem o `admin` continua capaz de alterar ou apagar a trilha. A imutabilidade plena exige que o armazenamento consultável não aceite alteração e que o uso do `admin` seja auditado, o que fica para o desenho do serviço.
- O serviço de consulta precisa de usuário Kafka próprio, criado por script como os demais ([ADR-009](ADR-009-kafka-sasl-ssl-scram.md)).
