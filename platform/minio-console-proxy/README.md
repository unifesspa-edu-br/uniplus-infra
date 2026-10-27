# minio-console-proxy

Proxy K8s para o MinIO Console externo (rodando como systemd no data-host). Apenas Service ExternalName + IngressRoute Traefik + Certificate cert-manager — **sem workload K8s**.

## Quando usar

Ative em ambientes que precisam expor o MinIO Console publicamente (UI admin do MinIO acessível por browser sem SSH tunnel). O Console não expõe a API S3 (porta 9000). A porta de dados só passa pelo Traefik nas rotas próprias deste chart, cada uma ligada à parte: o acervo público (`acervoPublicoProxy`) e a URL assinada (`portaDeDadosProxy`), descritos abaixo.

## Pré-requisitos

| Recurso | De onde vem |
|---|---|
| MinIO Console rodando no data-host | systemd `uniplus-minio` (port 9001) |
| cert-manager + ClusterIssuer LE prod | `platform/cert-manager/` |
| Traefik com entryPoint `websecure` | `platform/traefik/` |
| DNS público | CNAME `minio.<env>.<dominio>` → `<env>.<dominio>` |

## Auth

MinIO Console tem login próprio com root user/pwd custodiado em Vault `secret/standalone/minio/root`. Não há OIDC SSO configurado neste chart — para hml/prod considerar OpenID provider config nativo do MinIO server (`MINIO_IDENTITY_OPENID_*`).

## Acervo público (`acervoPublicoProxy`)

Rota da borda para o bucket público do MinIO ([ADR-0132](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0132-armazenamento-publico-separado-para-documento-publicado.md) do `uniplus-api`), ligada e desligada sem relação com o Console. Mesmo desenho: Service ClusterIP + EndpointSlice manual para a porta de dados (9000) do host + IngressRoute Traefik.

| Comportamento | Como |
|---|---|
| `https://<host>/acervo/<chave>` → `/<bucket>/<chave>` | Middleware `replacePathRegex`; o bucket é fixado no chart, nenhum outro bucket é alcançável pela rota |
| Só GET e HEAD | `Method(...)` no match da IngressRoute — o Traefik não tem middleware de filtro de método; outro método não casa com rota alguma e recebe 404 do Traefik |
| Leitura sempre anônima | Middleware de cabeçalhos descarta `Authorization` |
| Condição de origem avaliável | O mesmo middleware descarta `X-Forwarded-For`, `X-Real-Ip` e `Forwarded`: o MinIO avalia `aws:SourceIp` por esses cabeçalhos antes do endereço da conexão |
| Listagem recusada | `GET /acervo/` vira `ListObjects` anônimo, negado pela política (só `s3:GetObject`) |

Pré-requisitos: o bucket e a política criados por `scripts/lab-standalone-single/setup-minio.sh` (em HML, pelo wrapper `scripts/hml-standalone-single/setup-minio.sh`), e a porta 9000 do host em `networkPolicy.externalBackends` do `platform/traefik/`. Esta é a rota provisória; o nome próprio da borda, com cache e limite de taxa, é trabalho à parte. Roteiro de aplicação e smoke em `docs/RUNBOOKS.md` §21.8.

## Porta de dados para URL assinada (`portaDeDadosProxy`)

Nome próprio para a porta de dados (9000), pelo qual o navegador usa as URLs assinadas que a API devolve: download e envio direto de arquivo. A API assina com esse nome (`Storage__PublicEndpoint` + `Storage__PublicUseSSL`), e a assinatura SigV4 cobre Host e caminho.

| Comportamento | Como |
|---|---|
| Host e caminho preservados | Nenhum middleware de reescrita nem de cabeçalho; os de `ingress.middlewares` também não podem reescrever |
| Só os buckets listados | `Path(`/<bucket>`)` para a raiz do bucket e `PathRegexp(`^/<bucket>/.+`)` para objeto, por item de `buckets`; a raiz do host, `/<bucket>/` sem chave e qualquer outro bucket recebem 404 do Traefik |
| Sem cópia no servidor | A rota de PUT descarta `X-Amz-Copy-Source`: o envio grava o corpo enviado, nunca copia de outro bucket. O cabeçalho não entra na assinatura da URL |
| Acervo fora | Listar o bucket do acervo falha na renderização: a leitura pública do acervo só chega pela rota do acervo |
| Métodos de URL assinada | Objeto: GET, HEAD e OPTIONS; PUT só nos buckets com `envio: true`. Raiz do bucket: só GET e HEAD (a consulta de região da biblioteca do MinIO). DELETE, POST e escrita na raiz do bucket recebem 404 do Traefik |

Pré-requisitos: a porta 9000 do host em `networkPolicy.externalBackends` do `platform/traefik/` e o CORS do MinIO liberado para a origem do portal. Roteiro e smoke em `docs/RUNBOOKS.md` §21.11.

## Operação

Procedimentos detalhados em `docs/RUNBOOKS.md` §12.7 (acesso público via Console).
