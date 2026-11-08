# Runbooks operacionais

Procedimentos do ambiente `uniplus-prd`. A decisão da topologia está na [ADR-015](adrs/ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md). Os scripts ficam em `scripts/servicos-no-host/`, todos aceitam `--dry-run` e usam `AMBIENTE=prd` por padrão (`hml` também é aceito). Os caminhos dos segredos no Vault estão em [vault-caminhos.md](vault-caminhos.md).

## Sumário

1. [Rotina](#1-rotina)
2. [Produção em duas VMs](#2-produção-em-duas-vms)
3. [Atualização manual por tag](#3-atualização-manual-por-tag)
4. [Renovação do certificado](#4-renovação-do-certificado)
5. [Reinício das VMs e abertura do Vault](#5-reinício-das-vms-e-abertura-do-vault)
6. [Política do acervo público](#6-política-do-acervo-público)
7. [Diagnóstico](#7-diagnóstico)

## 1. Rotina

### 1.1 Verificação diária de saúde

1. No Grafana (`https://grafana.uniplus.unifesspa.edu.br`), conferir pods saudáveis, taxa de erro das APIs e consumer lag do Kafka.
2. No ArgoCD, conferir que nenhuma Application está `Degraded`.
3. Nas VMs, `systemctl is-active uniplus-postgres uniplus-redis uniplus-minio uniplus-kafka uniplus-rabbitmq` na infraestrutura.
4. Conferir o backup da noite anterior.

### 1.2 Deploy de mudança via GitOps

A produção lê os charts da tag publicada, nunca de `main` (ver [seção 3](#3-atualização-manual-por-tag)). O fluxo de uma mudança é: PR aprovado e mesclado em `main`, validação em homologação, tag, atualização da produção.

### 1.3 Adicionar um segredo no Vault

1. Gravar no KV do sistema dono (`uniplus-prd`, `geo-prd` ou `plataforma-prd`), no caminho interno que o chart declara. Segredo usado por mais de um sistema é gravado no KV de cada um (ver [vault-caminhos.md](vault-caminhos.md)).

   ```bash
   vault kv put uniplus-prd/<caminho> chave=valor
   ```

2. No chart, apontar o `ExternalSecret` para a store do sistema (`uniplus`, `geo` ou `plataforma`) e para o caminho interno. A store só atende os namespaces do próprio sistema.
3. Conferir o Secret criado: `kubectl get secret <nome> -n <namespace>`.

### 1.4 Rollback

Repetir o procedimento da [seção 3](#3-atualização-manual-por-tag) com a tag anterior. Em emergência, `kubectl rollout undo deployment/<nome> -n <namespace>`; como não há sync automático, o ArgoCD apenas mostra o desvio até o próximo sync manual.

## 2. Produção em duas VMs

| VM | IP | Papel |
|---|---|---|
| `uniplus-prod-app` | `200.139.48.121` | K3s: Traefik (80/443), ArgoCD, Vault, External Secrets, KES, APIs, web, Apicurio, verificador, ClamAV, observabilidade |
| `uniplus-prod-infra` | `200.139.48.122` | Docker + systemd: PostgreSQL com PostGIS, MinIO, Redis, Kafka, RabbitMQ; dados em `/var/lib/uniplus` |

As aplicações alcançam a infraestrutura pelo nome `uniplus-prod-infra.unifesspa.edu.br`, que o certificado curinga `*.unifesspa.edu.br` valida. Não há CA interna.

### 2.1 Portas

Firewall já ativo. A infraestrutura aceita só de `200.139.48.121`: 5432 (PostgreSQL), 6379
(Redis), 9000 (MinIO), 9092 (Kafka), 5671 (RabbitMQ AMQPS) e 15671 (gerência do RabbitMQ). A VM de
aplicação aceita 22, 80 e 443 de fora e as redes de pods e serviços (`10.42.0.0/16`, `10.43.0.0/16`).

Uma porta a mais é necessária: **7373 na VM de aplicação, apenas para `200.139.48.122`**. O MinIO
(infraestrutura) chega ao KES (cluster) por ela, com TLS e validação do certificado. O
`bootstrap-app.sh` abre a regra; o chart do KES a repete na NetworkPolicy (`kes.networkPolicy.hostCidrs`).
O KES é alcançado pelo nome `uniplus-prod-app.unifesspa.edu.br` (variável `KES_HOST`), que precisa
resolver para `200.139.48.121`.

### 2.2 Certificado

O par fica só nas VMs, nunca no Git: `/etc/uniplus/tls/unifesspa.edu.br.key` (0600) e
`/etc/uniplus/tls/unifesspa.edu.br-bundle.crt`. Quem opera a VM o instala antes de qualquer script.

Permissões: `/etc/uniplus` e `/etc/uniplus/tls` com `755`, para que os clientes leiam a cadeia
(`-bundle.crt`); a chave privada fica `600`, de `root`. Com `700` ou `750` nos diretórios, os clientes
falham ao ler a cadeia (sintoma: `curl` com erro 77).

### 2.3 Imagens do MinIO

As imagens `quay.io/minio/minio`, `quay.io/minio/mc` e `quay.io/minio/kes` exigem autenticação no
registro. Copiá-las de uma origem que já as tenha, para o runtime de cada VM:

- **`uniplus-prod-infra`** (MinIO e `mc` rodam no Docker, pelo `instalar-minio.sh`):

  ```bash
  docker save quay.io/minio/minio quay.io/minio/mc -o minio-docker.tar   # na origem
  docker load -i minio-docker.tar                                        # na VM de infraestrutura
  ```

- **`uniplus-prod-app`** (o KES roda no K3s):

  ```bash
  docker save quay.io/minio/kes -o kes.tar                               # na origem
  sudo k3s ctr images import --platform linux/amd64 kes.tar              # na VM de aplicação
  ```

O `--platform linux/amd64` evita um import truncado no containerd.

### 2.4 Bootstrap (ordem)

1. **Infra:** `scripts/servicos-no-host/bootstrap-infra.sh` na `uniplus-prod-infra`. Sobe os cinco
   serviços só com TLS (portas sem TLS desligadas) e libera as portas para a VM de aplicação.
2. **App:** com o repositório na tag de produção (`git checkout vX.Y.Z`),
   `scripts/servicos-no-host/bootstrap-app.sh --revisao=vX.Y.Z` na `uniplus-prod-app`. Instala K3s,
   Helm e ArgoCD, publica o Secret `uniplus-unifesspa-tls`, registra o cluster com o label
   `uniplus.io/revision=vX.Y.Z` e aplica o projeto e os ApplicationSets. Nada é sincronizado.
3. **Plataforma:** no ArgoCD, sincronizar à mão, nesta ordem, `storage` (a StorageClass que o Vault
   usa), `traefik`, `external-secrets` e `vault`.
4. **Vault:** inicializar e abrir (Shamir 5/3, ver [seção 5](#5-reinício-das-vms-e-abertura-do-vault)), fora dos scripts.
5. **Preparar o Vault para o External Secrets:** `configurar-vault.sh` (monta um KV v2 por sistema, `uniplus-prd`, `geo-prd` e `plataforma-prd`, habilita
   `auth/kubernetes` e cria, para cada sistema, uma política de leitura só no próprio KV e a role
   `external-secrets-<sistema>`). Idempotente. Precisa
   rodar antes de qualquer segredo ser semeado.
6. **Segredos e bancos**, na `uniplus-prod-infra`, com o Vault aberto e o token em mãos (pedido sem
   eco), nesta ordem: `semear-vault.sh`, `provisionar-bancos.sh`, `provisionar-kafka.sh` (tópico
   e usuário SCRAM do registro de acesso, CA do broker), `provisionar-verificacao.sh` e
   `provisionar-rabbitmq.sh`. Todos falam com `https://uniplus-vault.unifesspa.edu.br`.
7. **Segredos que vêm de fora** (não nascem em nenhum script; quem opera os grava no Vault):
   `smtp` (`host`, `username`, `password`), nos KVs `uniplus-prd` e `plataforma-prd` e o `client_secret` de cada client
   do Keycloak institucional, em `uniplus-prd` (`keycloak/uniplus-api-host`, `keycloak/uniplus-api-portal`,
   `keycloak/uniplus-api-selecao`) e em `plataforma-prd` (`keycloak/kafka-ui`, `keycloak/apicurio-registry`). Os
   clients são criados à parte no `keycloak.unifesspa.edu.br`.
8. **Primeiro sync da API em dois tempos:** `primeiro-sync.sh` (na VM de aplicação). O Job de
   migration (`PreSync`) roda antes da fase Sync e precisa da ServiceAccount e dos Secrets (banco,
   Redis, OAuth do Geo, RabbitMQ, e-mail) que só nascem nela; num ambiente vazio ele falharia e o
   ArgoCD abortaria o sync sem criar nada. No primeiro tempo o script faz um sync completo com o
   Job desligado só naquela operação (`uniplusApiHost.migrationJob.enabled=false` em
   `operation.sync.sources`; o `spec` e os values não mudam). Sem o hook, a fase Sync cria a
   ServiceAccount e os ExternalSecrets, e o schema é aplicado no boot do pod, correto num banco vazio.
   O script espera os Secrets e lista o que faltar no Vault. No segundo tempo, o sync normal da
   Application `uniplus-api-host` executa o Job com tudo já criado. Só o primeiro sync precisa dos
   dois tempos.
9. **Rota do ArgoCD:** `kubectl apply -f environments/uniplus-prd/argocd-ingressroute.yaml`
   (depois de o Traefik registrar os CRDs). Hosts de administração respondem só à rede institucional
   e à VPN (`middlewares.adminInterno.sourceRange`: `200.139.48.0/25` e `192.168.90.0/24`).
10. **Aplicações:** sincronizar as demais Applications, uma a uma. Depois do KES saudável, rodar
    `provisionar-arquivos-candidato.sh` na infraestrutura.

O emissor OIDC é o Keycloak institucional (`https://keycloak.unifesspa.edu.br/realms/unifesspa`).

### 2.5 Não verificável sem as VMs

Os scripts e os valores foram validados por renderização, `shellcheck` e `--dry-run`. Dependem de
conferência na primeira execução real: a imagem `postgis/postgis:18-3.6` aceitar `hba_file` e
`ssl_key_file` nos caminhos montados, o dono do diretório TLS de cada container (uids 999, 1000 e
100), o nome DNS `uniplus-prod-app` para o KES e a ordem de sync no ArgoCD.

## 3. Atualização manual por tag

Nenhuma Application de produção tem `syncPolicy.automated`: o ArgoCD só mostra o que mudou. A
revisão dos charts e dos valores é uma tag deste repositório, **validada antes em homologação**.

1. Criar e publicar a tag (`vX.Y.Z`) a partir do commit já validado em homologação.
2. Na `uniplus-prod-app`: `git fetch --tags && git checkout vX.Y.Z`.
3. `scripts/servicos-no-host/atualizar-producao.sh --revisao=vX.Y.Z`. Confere que o checkout está
   na tag, grava `uniplus.io/revision` no cluster e reaplica o projeto, os ApplicationSets e o
   verificador. As Applications passam a apontar para a tag.
4. No ArgoCD, revisar o diff de cada Application e sincronizar à mão. Nas APIs, o sync do
   `uniplus-api-host` roda a migração (`PreSync`); sincronizá-lo antes dos demais consumidores.
5. Reverter é repetir o procedimento com a tag anterior.

Sem o label `uniplus.io/revision` no cluster, o ApplicationSet falha de propósito em vez de seguir
`main`. O verificador usa o mesmo mecanismo (marcador `REVISAO_UNIPLUS_INFRA` trocado na aplicação).

## 4. Renovação do certificado

Nas duas VMs, uma de cada vez, com o mesmo par novo:

```bash
./scripts/servicos-no-host/renovar-certificado.sh --vm=infra --cert=novo-bundle.crt --key=nova.key
./scripts/servicos-no-host/renovar-certificado.sh --vm=app   --cert=novo-bundle.crt --key=nova.key
```

O script confere chave, validade e nome, guarda o par anterior em `/etc/uniplus/tls/anterior`,
reinstala o par para cada serviço e reinicia `uniplus-postgres`, `uniplus-redis`, `uniplus-minio`,
`uniplus-kafka` e `uniplus-rabbitmq` (infra), ou atualiza o Secret TLS dos namespaces, regrava no
Vault o certificado do KES e o CA do Kafka (`kafka/ca` e `kafka/admin`), espera os ExternalSecrets
sincronizarem e reinicia o KES (app). Na infra também troca o `kes.crt` em que o MinIO confia.
Fazer a VM de aplicação primeiro. O script fala com o Vault por port-forward neste host. Os clientes revalidam o certificado na próxima conexão; conferir depois com
`openssl s_client -connect uniplus-prod-infra.unifesspa.edu.br:5432 -starttls postgres`.

## 5. Reinício das VMs e abertura do Vault

- **Infra:** as cinco unidades `uniplus-*` sobem sozinhas (`systemctl is-active uniplus-postgres
  uniplus-redis uniplus-minio uniplus-kafka uniplus-rabbitmq`).
- **App:** o K3s e o ArgoCD voltam sozinhos. O Vault volta **selado** (Shamir 5/3, ADR-014):
  abrir pela interface em `https://uniplus-vault.unifesspa.edu.br` (restrita à rede institucional) ou
  por `kubectl exec` com três das cinco chaves. Enquanto selado, o External Secrets não renova
  segredos e as aplicações novas não sobem. Reiniciar a infra antes da app evita erros de conexão
  no início.

A inicialização do Vault (`operator init`, 5 chaves, limiar 3) é manual e fora dos scripts; cada
chave vai a um custodiante diferente.

## 6. Política do acervo público

A leitura anônima do bucket `uniplus-acervo-publico` só vale para quem chega pelo Traefik. A condição
`aws:SourceIp` em `scripts/servicos-no-host/minio/acervo-publico.policy.json` é `200.139.48.121/32`
(IP da VM de aplicação), no lugar de `10.42.0.0/16` de homologação, porque em produção o Traefik
alcança o MinIO por outra máquina e a origem da conexão é o IP público dela. Um `GET` anônimo
direto em `uniplus-prod-infra.unifesspa.edu.br:9000` a partir de outro IP é recusado.

## 7. Diagnóstico

- **ExternalSecret sem sincronizar:** `kubectl describe externalsecret <nome> -n <namespace>`. Causas comuns: Vault selado, caminho inexistente no KV do sistema, ou a store não atende o namespace (`spec.conditions` da `ClusterSecretStore`).
- **Application `OutOfSync` depois de atualizar a tag:** esperado; revisar o diff e sincronizar à mão.
- **Pod sem subir por imagem:** conferir `imagePullSecrets` e, para as imagens do MinIO, a [seção 2.3](#23-imagens-do-minio).
- **Cliente recusa o certificado das VMs:** conferir permissões de `/etc/uniplus/tls` ([seção 2.2](#22-certificado)) e a validade com `openssl x509 -noout -dates`.
- **Migração do `uniplus-api-host` falhou:** ver o passo do primeiro sync na [seção 2.4](#24-bootstrap-ordem).
