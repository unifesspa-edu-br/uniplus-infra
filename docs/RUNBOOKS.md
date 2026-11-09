# Runbooks operacionais

Procedimentos do ambiente `uniplus-prd`. A decisão da topologia está na [ADR-015](adrs/ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md). Os scripts ficam em `scripts/servicos-no-host/`, todos aceitam `--dry-run` e usam `AMBIENTE=prd` por padrão (`hml` também é aceito, exceto em `bootstrap-app.sh`: a homologação tem o próprio bootstrap). Os caminhos dos segredos no Vault estão em [vault-caminhos.md](vault-caminhos.md).

## Sumário

1. [Rotina](#1-rotina)
2. [Produção em duas VMs](#2-produção-em-duas-vms)
3. [Atualização manual de versão](#3-atualização-manual-de-versão)
4. [Renovação do certificado](#4-renovação-do-certificado)
5. [Reinício das VMs e abertura do Vault](#5-reinício-das-vms-e-abertura-do-vault)
6. [Política do acervo público](#6-política-do-acervo-público)
7. [Diagnóstico](#7-diagnóstico)

## 1. Rotina

### 1.1 Verificação diária de saúde

1. No Grafana (`https://grafana.uniplus.unifesspa.edu.br`), conferir pods saudáveis, taxa de erro das APIs e consumer lag do Kafka.
2. No ArgoCD, conferir que nenhuma Application está `Degraded`.
3. Nas VMs, `systemctl is-active uniplus-postgres uniplus-redis uniplus-minio uniplus-kafka uniplus-rabbitmq` na infraestrutura.

O backup em armazenamento independente ainda não está definido (pedido à CTIC). Até lá, antes de
qualquer mudança: `pg_dumpall` do PostgreSQL e `vault operator raft snapshot save` do Vault, guardados
fora das VMs. O snapshot do Vault é tão necessário quanto o dump: sem as chaves do Transit, os dados
cifrados do banco e os arquivos do MinIO ficam ilegíveis.

### 1.2 Deploy de mudança via GitOps

A produção lê os charts deste repositório num commit fixado em `prd/versao.yaml` do repositório de implantação, nunca de `main` (ver [seção 3](#3-atualização-manual-de-versão)). O fluxo de uma mudança é: PR aprovado e mesclado em `main`, validação em homologação, merge request no repositório de implantação que fixa o commit em `prd/`, sync manual em produção.

### 1.3 Adicionar um segredo no Vault

1. Gravar no KV do sistema dono (`uniplus-prd`, `geo-prd` ou `plataforma-prd`), no caminho interno que o chart declara. Segredo usado por mais de um sistema é gravado no KV de cada um (ver [vault-caminhos.md](vault-caminhos.md)).

   ```bash
   vault kv put uniplus-prd/<caminho> chave=valor
   ```

2. No chart, apontar o `ExternalSecret` para a store do sistema (`uniplus`, `geo` ou `plataforma`) e para o caminho interno. A store só atende os namespaces do próprio sistema.
3. Conferir o Secret criado: `kubectl get secret <nome> -n <namespace>`.

### 1.4 Rollback

Voltar a versão em `prd/` por merge request no repositório de implantação e sincronizar de novo ([seção 3](#3-atualização-manual-de-versão)). Em emergência, `kubectl rollout undo deployment/<nome> -n <namespace>`; como não há sync automático, o ArgoCD apenas mostra o desvio até o próximo sync manual.

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

- **`uniplus-prod-infra`** (MinIO e `mc` rodam no Docker, pelo `instalar-minio.sh`; a CLI do KES gera
  as identidades e cria a chave dos arquivos). As tags são as que os scripts usam:

  ```bash
  docker save quay.io/minio/minio:RELEASE.2025-09-07T16-13-09Z quay.io/minio/mc:latest \
    quay.io/minio/kes:2025-03-12T09-35-18Z -o minio-docker.tar           # na origem
  docker load -i minio-docker.tar                                        # na VM de infraestrutura
  ```

- **`uniplus-prod-app`** (o KES roda no K3s):

  ```bash
  docker save quay.io/minio/kes:2025-03-12T09-35-18Z -o kes.tar          # na origem
  sudo k3s ctr images import --platform linux/amd64 kes.tar              # na VM de aplicação
  ```

O `--platform linux/amd64` evita um import truncado no containerd.

### 2.4 Bootstrap (ordem)

1. **Infra:** `scripts/servicos-no-host/bootstrap-infra.sh` na `uniplus-prod-infra`. Sobe os cinco
   serviços só com TLS (portas sem TLS desligadas) e libera as portas para a VM de aplicação.
2. **App:** `scripts/servicos-no-host/bootstrap-app.sh` na `uniplus-prod-app`. Instala K3s,
   Helm e ArgoCD, grava a reescrita do CoreDNS que leva o nome do Vault ao Service dele
   (ConfigMap `coredns-custom`, ver [2.5](#25-tls-do-vault)), publica o Secret `uniplus-unifesspa-tls`
   (inclusive no namespace `vault`) e registra o cluster com os labels de ambiente. Nada é sincronizado.
   Em seguida, à mão: criar o Secret `repositorio-uniplus-deploy` com um token de leitura do
   repositório de implantação. No bootstrap o Vault ainda não está aberto, então o token é sempre
   um novo, criado no GitLab por um Maintainer (Configurações > Repositório > Tokens de implantação,
   escopo `read_repository`); o anterior é revogado. Depois do passo 5 ele é guardado no Vault de
   produção (KV `plataforma-prd`, caminho `gitlab/uniplus-deploy`). O token vai por stdin, sem
   quebra de linha final:

   ```bash
   printf '%s' "$TOKEN" | kubectl -n argocd create secret generic repositorio-uniplus-deploy \
     --from-literal=type=git --from-literal=url=<URL do repositório de implantação> \
     --from-literal=username="$USUARIO_DO_TOKEN" --from-file=password=/dev/stdin \
     --dry-run=client -o yaml | kubectl apply -f -
   kubectl -n argocd label secret repositorio-uniplus-deploy --overwrite \
     argocd.argoproj.io/secret-type=repository
   ```

   O `apply` cria o Secret ou troca o token num cluster que já o tenha.

   Depois, aplicar
   `prd/raiz.yaml` de um checkout da `main` do repositório de implantação (GitLab institucional),
   sincronizando a raiz **sem prune**. Ela gera o projeto, os ApplicationSets e o verificador.
   Até a rota do ArgoCD existir (passo 9 do resumo do bootstrap), o acesso é por port-forward a partir
   da VM, com o usuário `admin` e a senha inicial:

   ```bash
   kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
   kubectl -n argocd port-forward svc/argocd-server 8080:80    # http://localhost:8080 por túnel SSH (server.insecure)
   ```
3. **Plataforma:** no ArgoCD, sincronizar à mão, nesta ordem, `platform-storage` (a StorageClass que
   o Vault usa), `platform-traefik`, `platform-external-secrets` e `platform-vault`.
4. **Vault:** inicializar e abrir (Shamir 5/3, ver [seção 5](#5-reinício-das-vms-e-abertura-do-vault)), fora dos scripts.
5. **Preparar o Vault:** `configurar-vault.sh` habilita primeiro a auditoria em dois destinos, `stdout/`
   (saída do pod) e `file/` (`/vault/audit/audit.log`, rotacionado pelo sidecar `audit-rotate`), e
   confere-se com `vault audit list`. Depois monta um KV v2 por sistema (`uniplus-prd`, `geo-prd` e
   `plataforma-prd`), habilita `auth/kubernetes` e cria, para cada sistema, uma política de leitura só no
   próprio KV e a role `external-secrets-<sistema>`. Monta também um Transit por sistema
   (`uniplus-prd-transit`, `geo-prd-transit`, `plataforma-prd-transit`), cria as chaves de cifra e, para
   `uniplus-api-host` e `unifesspa-geo-api`, a política e a role com `update` só nas chaves de cada um
   (tabela em [`vault-caminhos.md`](vault-caminhos.md)). Idempotente. Precisa rodar antes de qualquer
   segredo ser semeado e antes do `provisionar-verificacao.sh`, que exige a `uniplus-kes-kek`.
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

### 2.5 TLS do Vault

O listener do Vault serve TLS com o certificado do domínio, montado do Secret `uniplus-unifesspa-tls` do
namespace `vault` (`tls.crt` com a cadeia completa). Nada fala com o Vault em texto claro, e nenhum cliente
pula a validação do certificado.

- **Nome:** o curinga não cobre `*.svc.cluster.local`, então os consumidores dentro do cluster
  (External Secrets, KES, APIs) chamam `https://uniplus-vault.unifesspa.edu.br:8200`. O nome é parâmetro do
  ambiente (values e `NOME_DO_VAULT` nos scripts; em outro ambiente que não `prd` a variável é obrigatória).
- **Resolução no cluster:** o `bootstrap-app.sh` grava o ConfigMap `coredns-custom` (`vault.override`),
  que o CoreDNS do K3s importa. Ele reescreve o nome público para `platform-vault.vault.svc.cluster.local`
  e devolve a resposta com o nome original. O ConfigMap não é do K3s, então `kubectl apply` é
  idempotente e uma atualização do K3s não o apaga; o CoreDNS só o relê ao reiniciar, e o script o
  reinicia quando o ConfigMap muda. Conferir de dentro do cluster:
  `kubectl -n vault exec platform-vault-0 -c vault -- nslookup uniplus-vault.unifesspa.edu.br` deve devolver o
  ClusterIP do Service `platform-vault`.
- **Validação:** as imagens do External Secrets (distroless) e do KES (UBI micro com o bundle de CAs) trazem as
  CAs públicas, as APIs .NET usam o repositório de CAs do sistema (já validam o Keycloak e o MinIO com o
  mesmo certificado), e o Traefik valida o backend pelo `ServersTransport` com `serverName` igual ao nome do
  Vault. Nada usa `skip-verify`. Se a cadeia entregue não chegar a uma raiz dessas imagens, a correção é
  completar a cadeia em `tls.crt`, não relaxar a validação.
- **Scripts:** sem `VAULT_URL`, abrem um port-forward para o pod e o `curl` resolve o nome do Vault para
  `127.0.0.1` só naquela porta; o certificado continua sendo validado pelo nome. A CLI dentro do pod
  (`kubectl -n vault exec platform-vault-0 -c vault -- vault status`) valida pelo `VAULT_TLS_SERVER_NAME`.
- **Renovação:** o `renovar-certificado.sh` troca o Secret, espera o kubelet projetá-lo no pod, manda o Vault
  reler o listener com `SIGHUP` (sem reiniciar, para não selá-lo) e confere o certificado servido.

### 2.6 Não verificável sem as VMs

Os scripts e os valores foram validados por renderização, `shellcheck` e `--dry-run`. Dependem de
conferência na primeira execução real: a imagem `postgis/postgis:18-3.6` aceitar `hba_file` e
`ssl_key_file` nos caminhos montados, o dono do diretório TLS de cada container (uids 999, 1000 e
100), o nome DNS `uniplus-prod-app` para o KES, a ordem de sync no ArgoCD e a sintaxe da reescrita do
CoreDNS (conferir com o `nslookup` da seção 2.5 antes de abrir o Vault).

## 3. Atualização manual de versão

Nenhuma Application de produção tem `syncPolicy.automated`: o ArgoCD só mostra o que mudou. A
versão dos charts e os values de produção vêm do repositório de implantação (GitLab institucional),
pasta `prd/`, e só chega lá o que já roda em homologação ([ADR-016](adrs/ADR-016-producao-le-o-repositorio-de-implantacao.md)).

1. **Backup**: dump do PostgreSQL e snapshot do Vault, guardados fora das VMs.
2. **Promover**: no pipeline do GitLab, o botão `prd:preparar:<componente>` confere a versão que
   roda em homologação e grava em `prd/` a versão e o digest da imagem conferida. Produção passa a
   referenciar a imagem como `tag@sha256:…`, a mesma que rodou em homologação.
3. **Hooks presos**: antes de sincronizar uma Application com hook, conferir que nenhum Job ou Pod
   ficou com o finalizer `argocd.argoproj.io/hook-finalizer` de um sync anterior. Um Job de migration
   antigo preso assim trava o sync em `Running` até o finalizer ser retirado.

   ```bash
   kubectl get jobs,pods -A -o json | jq -r '.items[] | select((.metadata.finalizers // []) | index("argocd.argoproj.io/hook-finalizer")) | [.kind, .metadata.namespace, .metadata.name] | @tsv'
   ```

4. **Sincronizar**: no ArgoCD de produção, revisar o diff de cada Application (só a imagem, com
   tag e digest, e os labels de versão devem mudar) e sincronizar à mão, **sem prune**, nesta
   ordem: `uniplus-api-host` primeiro (a migration roda em `PreSync`; se falhar, não repetir),
   depois portal, geo, verificador e web.
5. **Fumaça**: conferir os endereços de fumaça, que estão na saída do botão.
6. **Reverter**: voltar em `prd/`, por merge request no repositório de implantação, a versão e o
   digest que produção executava antes. No histórico de sync da Application (o ArgoCD só registra
   syncs bem-sucedidos), pegar a última entrada **anterior à atualização que se quer desfazer** e,
   nela, a revisão da source do repositório de implantação; o `prd/` dessa revisão traz o par.
   Depois, sincronizar de novo. Mudança de charts ou de values de produção também é por merge request lá.

## 4. Renovação do certificado

Nas duas VMs, uma de cada vez, com o mesmo par novo:

```bash
./scripts/servicos-no-host/renovar-certificado.sh --vm=infra --cert=novo-bundle.crt --key=nova.key
./scripts/servicos-no-host/renovar-certificado.sh --vm=app   --cert=novo-bundle.crt --key=nova.key
```

O script confere chave, validade e nome, guarda o par anterior em `/etc/uniplus/tls/anterior`,
reinstala o par para cada serviço e reinicia `uniplus-postgres`, `uniplus-redis`, `uniplus-minio`,
`uniplus-kafka` e `uniplus-rabbitmq` (infra), ou atualiza o Secret TLS dos namespaces, regrava no
Vault o certificado do KES e o CA do Kafka (`kafka/ca` e `kafka/admin`), manda o Vault reler o
certificado do listener (`SIGHUP`, sem selá-lo), espera os ExternalSecrets
sincronizarem e reinicia o KES (app). Na infra também troca o `kes.crt` em que o MinIO confia.
Fazer a VM de aplicação primeiro. O script fala com o Vault por port-forward neste host. Os clientes revalidam o certificado na próxima conexão; conferir depois com
`openssl s_client -connect uniplus-prod-infra.unifesspa.edu.br:5432 -starttls postgres`.

## 5. Reinício das VMs e abertura do Vault

- **Infra:** as cinco unidades `uniplus-*` sobem sozinhas (`systemctl is-active uniplus-postgres
  uniplus-redis uniplus-minio uniplus-kafka uniplus-rabbitmq`).
- **App:** o K3s e o ArgoCD voltam sozinhos. O Vault volta **selado** (Shamir 5/3, ADR-014):
  abrir pela interface em `https://uniplus-vault.unifesspa.edu.br` (restrita à rede institucional) ou
  por `kubectl -n vault exec -it platform-vault-0 -c vault -- vault operator unseal` com três das cinco
  chaves. Enquanto selado, o External Secrets não renova
  segredos e as aplicações novas não sobem. Reiniciar a infra antes da app evita erros de conexão
  no início.

A inicialização do Vault (`operator init`, 5 chaves, limiar 3) é manual e fora dos scripts; cada
chave vai a um custodiante diferente.

## 6. Política do acervo público

A leitura anônima do bucket `uniplus-acervo-publico` só vale para quem chega pelo Traefik. O
`instalar-minio.sh` gera a política do modelo `scripts/servicos-no-host/minio/acervo-publico.policy.json.modelo`,
com `aws:SourceIp` igual a `APP_CIDR` (por padrão `200.139.48.121/32`, o IP da VM de aplicação, porque em
produção o Traefik alcança o MinIO por outra máquina e a origem da conexão é o IP público dela; num host
só, é a rede de pods). Quem precisar de outra regra informa `ACERVO_PUBLICO_POLICY_FILE`, que vale como está. Um `GET` anônimo
direto em `uniplus-prod-infra.unifesspa.edu.br:9000` a partir de outro IP é recusado.

## 7. Diagnóstico

- **ExternalSecret sem sincronizar:** `kubectl describe externalsecret <nome> -n <namespace>`. Causas comuns: Vault selado, caminho inexistente no KV do sistema, ou a store não atende o namespace (`spec.conditions` da `ClusterSecretStore`).
- **Sync do `external-secrets` recusado com `failed calling webhook ... no endpoints available`:** a validação prévia do ArgoCD chama o webhook antes de qualquer onda; numa instalação do zero ele ainda não existe e a store espera a onda 1, mas se o webhook já está registrado e o pod dele está fora do ar a validação falha. Esperar o `external-secrets-webhook` ficar pronto (`kubectl get pods -n external-secrets`) e sincronizar de novo.
- **Application `OutOfSync` depois de atualizar a tag:** esperado; revisar o diff e sincronizar à mão.
- **Pod sem subir por imagem:** conferir `imagePullSecrets` e, para as imagens do MinIO, a [seção 2.3](#23-imagens-do-minio).
- **Cliente recusa o certificado das VMs:** conferir permissões de `/etc/uniplus/tls` ([seção 2.2](#22-certificado)) e a validade com `openssl x509 -noout -dates`.
- **Migração do `uniplus-api-host` falhou:** ver o passo do primeiro sync na [seção 2.4](#24-bootstrap-ordem).
