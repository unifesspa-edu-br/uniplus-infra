# Spike — Roteamento Host+PathPrefix sem StripPrefix (uniplus-api-host / Publicações)

> **Plano:** validação exploratória antes da cascata formal de issues (Epic → Features → Stories →
> Tasks) do ambiente HML real (`docs/RUNBOOKS.md §21`).
> **Data:** 2026-07-12
> **VM alvo:** `192.168.21.134` (real, dedicada, VPN-only) — ambiente permanece identificado como
> **spike**, não como HML operacional. Nenhum PR foi aberto para o conteúdo deste spike em si
> (chart e values ficaram fora do repositório, ver seção "O que NÃO foi commitado").
> **SHAs congelados:** `uniplus-infra@9fd7258` · `uniplus-api@778e380` (ambos `origin/main`)

## Resultado: PASS — gate fechado com evidência conjunta

| # | Critério do gate | Status | Evidência |
|---|---|---|---|
| 1 | `IngressRoute` live com `Host && PathPrefix`, sem middleware | PASS | `kubectl get ingressroute -o yaml` — ver seção 4 |
| 2 | Publicações inicializada com migrations reais | PASS | 5 `DbContext` sem migration pendente no boot (log) |
| 3 | Path completo → 200 direto no Service (port-forward) | PASS | seção 3 |
| 3b | Path sem prefixo → 404 direto no Service | PASS | seção 3 |
| 4 | Requisição externa (fora da VM) respondendo 200 | PASS | seção 5 |
| 4b | Host incorreto / path sem prefixo → 404 (assinatura do Traefik, não da app) | PASS | seção 5 |
| 5 | Mesmo `CorrelationId` no cliente e no log do Host | PASS | seção 6 |
| 6 | Log do Host mostrando o `RequestPath` completo (`/api/publicacoes/...`) | PASS | seção 6 |
| 7 | Controles negativos não alcançam a aplicação | PASS | seção 5 (sem `x-correlation-id`, sem vendor content-type) |
| 8 | Resultado preservado após restart do pod | PASS | seção 7 |

---

## 1. Escopo e decisões do spike

- **Alvo:** só o módulo Publicações (`GET /api/publicacoes/tipos-ato`, `GET /api/publicacoes/atos`
  — rotas reais, com regra de negócio e migrations). Portal ficou fora do deploy (só tem
  `/api/portal/ping` dummy) — usado como controle negativo de path.
- **Direto na VM real**, sem Docker Compose local prévio.
- **Imagem buildada na própria VM** a partir do SHA fixado (`docker/Dockerfile.host`).
- **Nenhum PR antes do spike** — `ConnectionStrings__PublicacoesDb` via `extraEnv` temporário,
  `IngressRoute` como manifesto avulso fora do repositório, ingress nativo do chart desligado.
- **K3s `v1.31.4+k3s1` (EOL) não bloqueou o spike** — decisão explícita do plano, já que a VM é
  dedicada e sem tráfego real; atualização fica como pré-requisito antes de a VM virar HML
  persistente.
- **Fundação replicada integralmente do `lab-standalone-single`** (Vault, ESO, Traefik+TLS
  autoassinado, Keycloak, Kafka, Apicurio Registry) — decisão tomada **durante** a execução: a
  tentativa inicial de reduzir escopo (desligar Kafka/Schema Registry) esbarrou num gotcha já
  documentado no próprio `values.yaml` do lab (Kafka desligado deixa o pod `Running` mas nunca
  `Ready`; o módulo Selecao, co-hospedado no mesmo processo, exige Schema Registry alcançável no
  boot quando Kafka está configurado). Replicar a fundação completa (já validada) foi mais rápido
  e seguro do que depurar uma combinação nova.

## 2. Achados/bugs encontrados e corrigidos durante o spike

Nenhum destes bloqueia o veredito do gate (todos contornados/corrigidos), mas são achados reais
que valem registro para as issues formais:

1. **DNS quebrado dentro de containers Docker** — `/etc/resolv.conf` do host (systemd-resolved)
   lista `192.168.21.13` como nameserver IPv4, mas esse endereço está inalcançável
   (`Destination Host Unreachable`) — só a resolução IPv6 funciona no host. Docker extrai
   nameservers do arquivo "legacy" e usa o primeiro (o quebrado), causando falha de `apt-get`
   dentro do build. **Corrigido**: `/etc/docker/daemon.json` com `dns: ["1.1.1.1", "8.8.8.8"]` +
   restart do Docker.
2. **Mesmo problema no CoreDNS do cluster** — `forward . /etc/resolv.conf` no `Corefile` herdava o
   mesmo nameserver quebrado, causando `SERVFAIL` ao resolver hostnames `nip.io` de dentro de
   pods. **Corrigido**: patch no ConfigMap `coredns` (`forward . 1.1.1.1 8.8.8.8`) + restart do
   deployment. **Ambos os achados são específicos desta VM/rede** (não necessariamente presentes
   em outra VM) — mas o padrão de correção (DNS explícito, não confiar no `/etc/resolv.conf` do
   host) vale a pena documentar como pré-requisito de bootstrap.
3. **Bug real e pré-existente em `scripts/lab-standalone-single/bootstrap.sh`** — o passo de
   unseal do Vault usa `vault operator unseal -` esperando ler a chave via stdin, mas o Vault CLI
   **não suporta essa convenção** (`-` é passado literalmente como a chave, que falha a validação
   hex/base64: `Error unsealing: 'key' must be a valid hex or base64 string`). Corrigido
   manualmente para este spike (chave passada como argumento posicional, conforme a própria
   mensagem de erro do Vault orienta). **Corrigido no repositório em 2026-07-12** — o mesmo bug
   também estava documentado como procedimento oficial em `docs/RUNBOOKS.md §8.4.2` (unseal manual
   do `standalone-compact`, produção real); ambos corrigidos: o script passa a chave como
   argumento posicional, o runbook passou a usar o prompt interativo mascarado nativo do
   `vault operator unseal` (sem `-`, sem pipe).
4. **Timeout de 60s do Postgres no primeiro boot** — o pull da imagem `postgis/postgis:18-3.6`
   (~1-2GB, primeira vez) mais o ciclo padrão `initdb`+restart dos entrypoints oficiais do Postgres
   excedeu o timeout fixo do script. Sem impacto real (Postgres ficou saudável poucos segundos
   depois) — re-rodar o script (idempotente) resolveu. Vale considerar aumentar o timeout ou
   adicionar retry no script, mas não é bloqueante.

## 3. Validação direta no Service (port-forward, sem Traefik)

```
GET /api/publicacoes/tipos-ato  → 200, content-type: application/vnd.uniplus.tipo-ato.v1+json
GET /api/publicacoes/atos       → 200, content-type: application/vnd.uniplus.ato-normativo.v1+json
GET /tipos-ato (sem prefixo)    → 404
GET /atos (sem prefixo)         → 404
GET /health/live                → 200
```

## 4. IngressRoute aplicado (manifesto avulso, fora do repositório)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: spike-uniplus-api-host-pathprefix
  namespace: uniplus
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(`uniplus-api-hml.192.168.21.134.nip.io`) && PathPrefix(`/api/publicacoes`)
      kind: Rule
      services:
        - name: uniplus-api-host-uniplus-api-host
          port: 8080
  tls:
    secretName: uniplus-wildcard-nip-io-tls
```

Confirmado via `kubectl get ingressroute -o yaml`: objeto live idêntico ao aplicado, **sem**
`middlewares` (sem `StripPrefix`).

## 5. Prova externa diferencial (de fora da VM, via VPN)

| Caso | Resultado | Assinatura |
|---|---|---|
| Host correto + `/api/publicacoes/tipos-ato` | `200` | `content-type: application/vnd.uniplus.tipo-ato.v1+json`, `x-correlation-id` ecoado |
| Host correto + `/api/publicacoes/atos` | `200` | `content-type: application/vnd.uniplus.ato-normativo.v1+json`, `x-correlation-id` ecoado |
| Host **incorreto** + path válido | `404` | `content-type: text/plain`, sem `x-correlation-id`, sem `link` — 404 do **Traefik**, requisição nunca chegou na app |
| Host correto + `/api/portal/ping` (fora do `PathPrefix`) | `404` | mesma assinatura acima — 404 do Traefik |

## 6. Rastreamento por Correlation ID no log da aplicação

Requisição externa com `X-Correlation-Id: 39858c04-638a-40e2-af0d-e32acc881d4c`:

```
[23:14:57 Information] HTTP GET /api/publicacoes/tipos-ato respondeu 200 em 4.3998ms
  RequestPath: "/api/publicacoes/tipos-ato"
  CorrelationId: "39858c04-638a-40e2-af0d-e32acc881d4c"

[23:14:57 Information] HTTP GET /api/publicacoes/atos respondeu 200 em 7.4039ms
  RequestPath: "/api/publicacoes/atos"
  CorrelationId: "39858c04-638a-40e2-af0d-e32acc881d4c"
```

`CorrelationId` do log bate exatamente com o header enviado pelo cliente; `RequestPath` mostra o
path **completo**, confirmando que o Traefik não removeu o prefixo (`StripPrefix` de fato ausente).

## 7. Resiliência pós-restart

```bash
kubectl rollout restart deployment/uniplus-api-host-uniplus-api-host -n uniplus
kubectl rollout status deployment/uniplus-api-host-uniplus-api-host -n uniplus --timeout=120s
# deployment "uniplus-api-host-uniplus-api-host" successfully rolled out
```

Nova requisição externa (`X-Correlation-Id: 458e50eb-4ddf-4e8b-bcae-edaf32e0ff29`) →
`200`, mesmo vendor media type. Resultado não era coincidência de estado.

## 8. O que NÃO foi commitado (fica só nesta VM de spike)

- `environments/_spike-pathprefix-hml/values.yaml` (worktree detached descartável, não commitado).
- `IngressRoute spike-uniplus-api-host-pathprefix` (manifesto avulso, aplicado via `kubectl apply`,
  fora do Git).
- `ConnectionStrings__PublicacoesDb` via `extraEnv` (paliativo — o chart real precisa ganhar essa
  connection string nativamente).
- Certificado autoassinado `*.192.168.21.134.nip.io` (gerado só para este spike, chave privada já
  destruída — `shred -u`).

## 9. O que isso desbloqueia (para a cascata formal de issues)

Confirmado tecnicamente viável, sem ambiguidade: `Host() && PathPrefix()` sem `StripPrefix` é o
padrão correto para expor APIs de negócio do `uniplus-api-host` sob um host único, preservando o
path completo que os controllers já esperam. As issues formais podem agora assumir isso como fato
validado (não mais suposição), e focar em:

- Suporte a `PathPrefix` nos templates `IngressRoute` de `apps/uniplus-web`,
  `apps/uniplus-api-{portal,host}` (hoje só `Host()`), incluindo as regras para as rotas
  transversais (`/api/auth`, `/api/profile`, `/openapi` — Host é o dono; ver §21.3 e item 10
  abaixo).
- `ConnectionStrings__PublicacoesDb` nativo no chart `apps/uniplus-api-host`.
- ~~Correção do bug de `vault operator unseal -`~~ — **feito** (item 10).
- Mecanismo por-ambiente no `argocd/applicationset.yaml` (achado de rodada anterior de revisão).
- ~~Atualização da versão do K3s (EOL)~~ — **feito** (item 10).
- Trabalho cross-repo no `uniplus-web` (Angular) para path-based routing — não coberto por este
  spike, esforço médio já mapeado em `docs/RUNBOOKS.md §21.3`.

## 10. Atualizações pós-spike (2026-07-12)

Fechamento de pontas soltas decidido em conversa após o gate, antes da cascata formal de issues:

- **Rotas transversais** — decisão de dono registrada em `docs/RUNBOOKS.md §21.3` (tabela
  completa): Host é dono de `/api/auth`, `/api/profile`, `/openapi/*`; `/health*` não precisa de
  rota no Traefik (probes do K8s batem direto no pod); `/api/_smoke/*` está sendo removido do
  código ([uniplus-api#829](https://github.com/unifesspa-edu-br/uniplus-api/issues/829)).
- **Bug do `vault operator unseal -` corrigido** em dois lugares: `scripts/lab-standalone-single/bootstrap.sh`
  (chave como argumento posicional) e `docs/RUNBOOKS.md §8.4.2` (procedimento de produção real do
  `standalone-compact` — trocado pelo prompt interativo mascarado nativo do `vault`, sem `-`/pipe).
- **K3s e Helm atualizados** em `scripts/lab-standalone-single/bootstrap.sh` e
  `scripts/bootstrap-standalone.sh`: `K3S_VERSION` de `v1.31.4+k3s1` (EOL nov/2025) para
  `v1.36.2+k3s1` (mais recente estável, mai/2026); `HELM_VERSION` de `v3.16.4` para `v3.21.2`
  (última minor da série 3.x — **não** Helm 4, que é major version nova sem validação de
  compatibilidade com os charts deste repo). `ARGOCD_VERSION` **não** atualizado — v2.14→v3.x é
  salto de major com guia de migração dedicado, avaliação própria fica fora do escopo desta
  rodada.
- **VM do spike derrubada por completo** (Opção A — volta ao estado antes do spike): K3s
  desinstalado, Vault/ESO/Traefik/Keycloak/Apicurio/uniplus-api-host desinstalados, serviços
  systemd de dados parados/removidos, `/var/lib/uniplus` apagado, imagens Docker removidas. Disco
  confirmado de volta a 12G usado / 81G livre, idêntico ao preflight original (§ deste documento
  não repete os comandos — só o registro de que a VM está limpa para um bootstrap novo). Mantido
  de propósito: `/etc/docker/daemon.json` (fix de DNS), já que é correção real, não resquício do
  spike.
