# Incidente: DNS interno inalcançável bloqueou GitOps no `hml-standalone-single`

> **Contexto:** verificação ao vivo do PR #471 (uniplus-infra, story #457/#458/#459 — mecanismo de
> habilitação por-ambiente no ApplicationSet). Ao conectar na VM para observar o efeito real do PR,
> encontrado um incidente **não relacionado** ao PR que já estava em andamento: todas as 22
> `Application`s do ArgoCD estavam com `sync.status: Unknown` havia mais de 1 dia.
>
> **Data:** 2026-07-15 · **VM:** `hml-standalone-single` (`192.168.21.134`)

## Resultado: causa raiz identificada e mitigada — GitOps normalizado

## 1. Sintoma

```
kubectl -n argocd get applications -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status'
```

Todas as 22 `Application`s (9 `apps/` + 13 `platform/`) com `SYNC: Unknown`, `HEALTH: Healthy`
(saúde cacheada do último estado bom conhecido). Condição reportada em cada `Application`:

```
Failed to load target state: failed to generate manifest for source 1 of 2: rpc error:
code = Unknown desc = failed to list refs:
Get "https://github.com/unifesspa-edu-br/uniplus-infra/info/refs?service=git-upload-pack":
dial tcp: lookup github.com on 10.43.0.10:53: server misbehaving
```

O ArgoCD repo-server não conseguia resolver `github.com` — nenhuma `Application` conseguia
comparar contra o Git, então nada progredia (nem as já existentes, nem as 2 novas do PR #471).

## 2. Diagnóstico

Descartadas por evidência direta (1-2), causa raiz confirmada por eliminação + teste direto (3-4):

1. **NetworkPolicy bloqueando egress do CoreDNS** — `kubectl -n kube-system get networkpolicy`
   retornou vazio. Não é isso.
2. **Flannel não fazendo SNAT do tráfego pod→LAN** — `iptables -t nat -L FLANNEL-POSTRTG -n -v`
   mostrou a regra `MASQUERADE 10.42.0.0/16 !224.0.0.0/4` ativa e com contadores altos; um pod de
   teste alcançou o gateway (`192.168.21.254`) normalmente (0,7ms, 0% perda). Não é isso.
3. **`192.168.21.13` (servidor DNS interno IPv4 da UNIFESSPA) estava inalcançável desta VM** —
   confirmado via `ping` **direto do host** (não só de pod): `Destination Host Unreachable` (nível
   de rede/roteamento, não timeout de firewall). O gateway (`192.168.21.254`) respondia normal.
4. O host continuava resolvendo DNS porque `systemd-resolved` **preferia o nameserver IPv6**
   (`2001:12f0:d88::894`, resolveu `github.com` em 52ms via `dig`). Os **pods não têm rota IPv6
   nenhuma** (Flannel/K3s aqui é IPv4-only — só endereços link-local `fe80::` nas interfaces
   `cni0`/`flannel.1`) — quando o único nameserver IPv4 configurado caiu, o CoreDNS ficou sem
   nenhuma rota funcional, mesmo o host tendo internet normal.

`resolvectl status` confirmou os 3 nameservers efetivamente usados pelo host (herdados também
pelo CoreDNS via `/run/systemd/resolve/resolv.conf`, não o stub `127.0.0.53`):
`192.168.21.13`, `2001:12f0:d88::894`, `2001:12f0:d8c:200::36`.

Confirmado que pods alcançam a internet pública em geral (`ping`/`nslookup` contra `1.1.1.1`
funcionaram, ~49ms) — não é um ambiente sem saída à internet, só o servidor DNS interno específico
que estava fora do ar.

## 3. Mitigação aplicada

`ConfigMap coredns` (namespace `kube-system`) — `forward` alterado de `/etc/resolv.conf` (lista
herdada do host, sem controle de política) para uma lista explícita com fallback público
sequencial:

```diff
-    forward . /etc/resolv.conf
+    forward . 192.168.21.13 1.1.1.1 1.0.0.1 {
+        policy sequential
+    }
```

- `policy sequential` mantém `192.168.21.13` como primeira tentativa sempre — quando ele voltar,
  volta a ser usado automaticamente (preserva resolução de nomes internos da UNIFESSPA quando
  esse servidor também os atender).
- Cai para os públicos (`1.1.1.1`/`1.0.0.1`, Cloudflare) só quando o interno falhar.
- As 2 entradas IPv6 foram removidas da lista — inúteis para os pods hoje (sem rota), só
  atrasavam cada tentativa de resolução com "network unreachable".
- Backup do `ConfigMap` original salvo em `/tmp/coredns-cm-backup-20260715-200343.yaml` **na
  própria VM** (não versionado — este documento é o registro).
- Aplicado via `kubectl apply`; o plugin `reload` do CoreDNS (já presente no Corefile) detectou a
  mudança e recarregou em ~30-45s, sem restart do pod (confirmado via `[INFO] Reloading complete`
  nos logs).

## 4. Resultado

Após o reload, `nslookup github.com` de um pod de teste resolveu (`4.228.31.150`). Refresh forçado
(`argocd.argoproj.io/refresh=normal`) em todas as `Application`s — as 22 voltaram a
`SYNC: Synced`, `HEALTH: Healthy`.

Achado colateral relevante para o PR #471: `uniplus-web-in-cluster` (registrado sempre-ligado, mas
com `uniplusWeb.enabled: false` no overlay deste ambiente) sincronizou como `Synced`/`Healthy` com
**0 recursos gerenciados** — confirma ao vivo, e não só por relatório anterior, que uma
`Application` cujo chart renderiza vazio não é bloqueada por `syncPolicy.automated.allowEmpty:
false` (essa proteção existe para impedir prune acidental de uma Application que **já tinha**
recursos, não para recusar uma que nasce vazia por design). É a mesma premissa usada no desenho do
mecanismo de habilitação por-ambiente do PR #471 para `uniplus-api-host`/`unifesspa-geo-api`.

## 5. Pendências / follow-up

- **Fora do escopo Kubernetes:** por que `192.168.21.13` ficou inalcançável — é infraestrutura de
  rede da UNIFESSPA (possível problema de VPN/roteamento específico para esse host), não algo
  corrigível a partir do cluster. Reportado à Divisão de Redes/CTIC (Idelvandro) por email.
- **Mitigação é paliativa, não definitiva:** enquanto `192.168.21.13` seguir instável, nomes
  *internos* exclusivos da UNIFESSPA (não resolvíveis publicamente) continuarão falhando quando o
  fallback público for usado — isso não afetou o ArgoCD (só depende de `github.com`, público), mas
  pode afetar outro componente que dependa de resolução interna.
- **Sem rota IPv6 para pods** é uma característica estrutural do cluster (Flannel IPv4-only) e não
  foi alterada — permanece como gap conhecido, não corrigido aqui (mudança de maior porte,
  precisaria de planejamento próprio se algum dia for necessário dual-stack).
- Verificar, após o merge do PR #471, que `uniplus-api-host-in-cluster` e
  `unifesspa-geo-api-in-cluster` aparecem como novas `Application`s (`Synced`/`Healthy`, 0
  recursos, namespaces `uniplus` e `geo` respectivamente) — não observado ainda porque o PR não
  estava mergeado no momento desta sessão.
