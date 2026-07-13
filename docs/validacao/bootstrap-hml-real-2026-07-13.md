# Bootstrap real do `hml-standalone-single` — VM dedicada (192.168.21.134)

> **Contexto:** Story #445 (Feature #435, Epic #434). `scripts/hml-standalone-single/bootstrap.sh`
> executado de fato contra a VM real, seguido do registro do cluster no ArgoCD. Complementa o
> spike de PathPrefix (`docs/validacao/spike-pathprefix-hml-2026-07-12.md`), que validou a
> mecânica de roteamento numa execução descartável — este documento registra o bootstrap
> **persistente**, que fica de pé.
>
> **Data:** 2026-07-13 · **SHA congelado:** `uniplus-infra` (branch `main` após PR #463 + #464)

## Resultado: fundação de pé, Vault aguardando init manual

O bootstrap da fundação (`bootstrap.sh`, sem `--dry-run`) rodou até o fim com sucesso. O cluster
foi registrado no ArgoCD e o `ApplicationSet` reconciliou 22 Applications. A etapa de
`vault operator init` + unseal foi **deliberadamente não executada** nesta sessão — gera 5 shares
Shamir que exigem custódia humana real (ver ADR-014), incompatível com execução autônoma
sem operador presente. Retomar via `docs/RUNBOOKS.md §8.4` (adaptado para 5/3), assim que houver
disponibilidade de um operador humano.

## 1. Estado inicial da VM (antes do bootstrap)

Confirmado via SSH, batendo com o estado documentado em `docs/RUNBOOKS.md §21.6` e com o estado
pós-teardown do spike (`docs/validacao/spike-pathprefix-hml-2026-07-12.md`, seção 8):

```
Disco: 12G usado / 81G livre (idêntico ao pós-teardown do spike)
Docker: v29.6.1 (já instalado)
K3s / kubectl: ausentes
sudo sem senha: OK
Arquitetura: x86_64
```

**Discrepância encontrada:** Helm CLI já estava instalado (`/usr/local/bin/helm`, v3.16.4),
resíduo do spike não removido no teardown (só componentes K3s-managed foram removidos; o binário
standalone do Helm não). `step_install_helm` é idempotente (não força reinstalação) — a VM roda
com Helm 3.16.4 em vez do 3.21.2 pinado no script. Sem impacto prático: nem `bootstrap.sh` nem o
ArgoCD (que usa Helm como biblioteca Go embutida, não o binário CLI do sistema) dependem do Helm
CLI do host para esta fase.

## 2. Achado real durante a execução — corrigido em produção (PR #464)

`step_patch_coredns` falhava com `Error from server (NotFound): deployments.apps "coredns" not
found` logo após `systemctl start k3s` — `kubectl wait --for=condition=available` exige que o
objeto já exista; o deploy controller do K3s leva alguns segundos para aplicar os addons bundled
(coredns, local-path-provisioner, metrics-server). **Não reproduzível em `--dry-run`**, que nunca
consulta a API do K3s — só apareceu na execução real. Corrigido com um loop de poll aguardando o
Deployment existir antes do `kubectl wait` (PR #464, aplicado e revalidado ao vivo antes do
re-bootstrap).

## 3. Bootstrap da fundação — resultado por componente

| Componente | Resultado |
|---|---|
| Docker + fix DNS | OK (DNS já corrigido de sessão anterior — preservado, idempotente) |
| K3s `v1.36.2+k3s1` | OK — node `uniplus-hml` Ready |
| CoreDNS (fix do spike) | OK, após o fix do PR #464 |
| Helm | OK (binário pré-existente, ver discrepância acima) |
| ArgoCD `v2.14.3` self-hosted | OK — 7 pods Running, disponível em < 5min |
| Postgres 18 + PostGIS 3.6 | OK — `pg_isready -h 127.0.0.1` (fix TCP) evitou a race com o servidor temporário do entrypoint |
| Role+DB `keycloak` | OK — criado via `docker exec --env-file` (fix argv) |
| Role+DB `apicurio` | OK — criado via `docker exec --env-file` (fix argv) |
| Kafka 4.2.0 KRaft (SASL_SSL+SCRAM) | OK — `--add-scram` via arquivo montado + `sh -c` fixo (fix argv), aceitando conexões SASL_SSL |
| Certificado TLS autoassinado | OK — Secret `uniplus-wildcard-nip-io-tls` criado no namespace `uniplus`, SAN `*.192.168.21.134.nip.io` |

Todos os fixes aplicados durante o ciclo de revisão Codex do PR #463 (9 rodadas — endereço do
Vault, DB nunca provisionado, DNS quebrado, timeout do Postgres, senha em argv em 2 mecanismos
diferentes, ownership de arquivo pro UID do container, race do `pg_isready`, auto-detecção de IP,
arm64) se confirmaram necessários e corretos na execução real — nenhuma regressão.

## 4. Registro no cluster ArgoCD

```bash
argocd cluster add default --in-cluster --name in-cluster \
  --label uniplus.io/managed=true --label environment=hml-standalone-single
```

**Confirmado empiricamente:** o nome resultante do cluster é o literal `in-cluster` — mas **porque
`--name in-cluster` foi passado explicitamente**, não por comportamento implícito de
`--in-cluster` sozinho (achado do Codex no PR #463, contrato documentado em
`docs/RUNBOOKS.md §21.7`). `clusterSecretStore.vaultServer` em
`environments/hml-standalone-single/values.yaml` (`platform-vault-in-cluster...`) está correto.

`kubectl apply -f argocd/project.yaml` + `argocd/applicationset.yaml` reconciliaram 22
Applications (9 de `apps/` + 13 de `platform/`).

## 5. Estado final das Applications (snapshot)

17 de 22 `Synced` + `Healthy`. 5 pendentes, todas com causa raiz identificada e esperada:

| Application | Status | Health | Causa |
|---|---|---|---|
| `platform-vault-in-cluster` | Unknown | Progressing | Vault sealed/não inicializado (esperado — ver seção 6) |
| `keycloak-replica-in-cluster` | Synced | Degraded | `CreateContainerConfigError` — Secret do DB só existe após ClusterSecretStore ativo (ESO precisa do Vault desselado) |
| `apicurio-registry-in-cluster` | Synced | Progressing | Mesma causa — Secret do DB pendente do Vault |
| `platform-external-secrets-in-cluster` | Unknown | **Healthy** | Ver achado da seção 7 — pods `1/1 Running`, só o `STATUS` da comparação do ArgoCD está errado |
| `platform-traefik-in-cluster` | Unknown | **Healthy** | Idem — pod `1/1 Running` |

Nenhuma das 5 pendências indica falha real de aplicação dos manifests — confirmado via
`kubectl get pods -A` (seção 7).

## 6. Vault — pronto para init, aguardando operador

```
$ kubectl exec -n vault platform-vault-in-cluster-0 -- vault status
Seal Type       shamir
Initialized     false
Sealed          true
Storage Type    raft
HA Enabled      true
```

Exatamente o estado esperado (ADR-014: Shamir 5/3, não o 1/1 do lab). **Deliberadamente não
executado nesta sessão** — `vault operator init -key-shares=5 -key-threshold=3` gera 5 unseal keys
que precisam de custódia humana real e distribuída (ver ADR-014, seção "Custódia das 5 shares").
Nenhum agente autônomo deveria ser o único a manusear essas chaves sem um operador humano presente
para recebê-las.

**Procedimento para retomar** (`docs/RUNBOOKS.md §8.4`, adaptado — threshold 5/3 já é o padrão de
lá, só o pod/namespace mudam para `platform-vault-in-cluster` / `vault`). **Não** rodar
`vault operator init` direto no terminal (imprimiria as 5 unseal keys + root token em texto
puro no stdout/scrollback, sem nenhum artefato protegido para custódia) — seguir o fluxo seguro
de `docs/RUNBOOKS.md §8.4.1` (arquivo mode 0600 criado ANTES do redirect, nunca no terminal):

```bash
ssh jeferson@192.168.21.134

# Init — output (5 unseal keys + root token) vai DIRETO pro arquivo, nunca pro terminal.
# mode 600 criado ANTES do redirect (evita janela de exposição a outros usuários do host).
INIT_FILE=$(mktemp -t vault-init.XXXXXX.json)
chmod 600 "$INIT_FILE"
kubectl -n vault exec platform-vault-in-cluster-0 -- \
  vault operator init -format=json -key-shares=5 -key-threshold=3 > "$INIT_FILE"
echo "Init output em $INIT_FILE — exportar para gestor institucional (distribuir as 5 shares"
echo "entre custodiantes distintos, ver ADR-014) e rodar 'shred -u $INIT_FILE' depois."

# Unseal (3x, prompt mascarado nativo — chave nunca toca terminal/argv):
kubectl -n vault exec -it platform-vault-in-cluster-0 -- vault operator unseal
kubectl -n vault exec -it platform-vault-in-cluster-0 -- vault operator unseal
kubectl -n vault exec -it platform-vault-in-cluster-0 -- vault operator unseal
# Configurar auth Kubernetes + policy/role external-secrets (docs/RUNBOOKS.md §8.4.3, adaptado)
# ArgoCD reconcilia sozinho (self-heal) assim que a role existir — sem precisar re-sync manual
```

## 7. Achado adicional (não bloqueante): gap de schema K3s 1.36 × ArgoCD 2.14.3

`platform-vault-in-cluster`, `platform-traefik-in-cluster` e `platform-external-secrets-in-cluster`
mostram `ComparisonError`:

```
Failed to compare desired state to live state: failed to calculate diff: error calculating
structured merge diff: error building typed value from live resource:
.status.terminatingReplicas: field not declared in schema
```

`terminatingReplicas` é um campo novo no `status` de Deployment/StatefulSet que a versão do K8s
embutida no K3s `v1.36.2+k3s1` já expõe, mas que o schema OpenAPI embutido no ArgoCD `v2.14.3`
ainda não reconhece — gap de 5 minors entre o K3s pinado e a matriz oficialmente testada pelo
ArgoCD (`docs/RUNBOOKS.md §21.7` já sinalizava esse risco, achado de revisão do PR #463).

**Confirmado que é cosmético, não bloqueia aplicação real:**

```
$ kubectl get pods -n traefik -n external-secrets
platform-traefik-in-cluster-...            1/1   Running
platform-external-secrets-in-cluster-...   1/1   Running
platform-external-secrets-in-cluster-cert-controller-...   1/1   Running
platform-external-secrets-in-cluster-webhook-...            1/1   Running
```

Os manifests aplicam e os Pods sobem normalmente — só a comparação de status do ArgoCD (usada para
`Synced`/`OutOfSync`) erra nesses três Applications especificamente (todas têm Deployment ou
StatefulSet). Não resolvido nesta sessão — fica registrado como acompanhamento: se persistir após
o Vault desselado (quando dará pra validar Vault healthy de verdade), avaliar downgrade pontual do
K3s para a faixa testada pelo ArgoCD 2.14.3 (até 1.31) ou aguardar upgrade do ArgoCD (fora de
escopo de rotina, salto de major version).

## 8. Não executado nesta sessão (para retomar)

- `vault operator init` + unseal + configuração de auth/policy/role (seção 6)
- Seed dos secrets que Keycloak/Apicurio esperam via `ExternalSecret` (senhas dos DBs já geradas em
  `/var/lib/uniplus/postgres/.bootstrap-creds-{keycloak,apicurio}` na VM, aguardando custódia +
  `vault kv put`)
- Custódia formal das senhas geradas (Postgres, Keycloak DB, Apicurio DB, Kafka admin) — todas em
  arquivos `root:root 600` na VM, avisos de "custódia obrigatória" já emitidos pelo script
- `scripts/validate-standalone.sh` (ou equivalente adaptado para este ambiente) após o Vault estar
  operacional
- Acompanhamento do gap de schema K3s×ArgoCD (seção 7)
