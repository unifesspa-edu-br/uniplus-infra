# Environment: standalone-compact

Único ambiente operacional do Uni+ (2026-05-19). Topologia single-DC,
single-host, provider-agnostic na intenção, provisionada hoje em OCI GRU.
Decisão de topologia em [ADR-008](../../docs/adrs/ADR-008-topologia-standalone.md).

> O modelo dos 3 DCs (SP1+SP2+PA1) que este overlay outrora acompanhava nunca
> foi provisionado e foi removido do repositório em 2026-05-19. Ver
> [docs/ARCHITECTURE.md §5.5](../../docs/ARCHITECTURE.md#55-topologias-suportadas)
> e `docs/REPRODUCIBILITY.md`.

## Topologia em uma frase

Um cluster K3s em um host (`k8s-host`, Reserved Public IP) + um host externo
(`data-host`, IP privado fixo `10.2.2.11`) com componentes stateful gerenciados
por systemd (Postgres, Kafka, MinIO, Redis, Vault). Vault em selo **Shamir 5/3
manual** (o auto-unseal via OCI KMS está como follow-up — ver issue #384).

## Quando usar / quando não usar

- ✅ Validação integrada ponta a ponta, demos, aprendizado, fallback emergencial.
- ❌ HA geográfico, failover entre DCs, replicação MinIO cross-site, consenso
  Patroni/Kafka cross-DC, atendimento de pico de edital com SLA — exigem 3-DC.

## Limitações conhecidas

| Aspecto | Limitação |
|---|---|
| Resiliência | Single-host: queda da VM derruba toda a plataforma |
| Postgres | Single-primary por banco (sem replica, sem Patroni) |
| Vault | 1 réplica + Shamir 5/3 manual; re-init pós-teardown re-gera as keys |
| Keycloak | OIDC/JWT local; federação Gov.br fora do MVP |
| Storage | `reclaimPolicy: Delete` — re-bootstrap apaga PVs |
| Observabilidade | Stack único (Prometheus/Loki/Tempo single-replica), retenção curta |
| Performance | Não modela latência cross-DC — bugs geográficos ficam invisíveis aqui |

> **Risco a fiscalizar:** standalone passar e um futuro 3-DC falhar é um modo
> conhecido. Bugs sensíveis a partição de rede e latência cross-site **não** são
> detectáveis aqui.

## Provider-specifics

Por regra (ADR-008), nada provider-specific (OCIDs, ARNs, endpoints de cloud,
credenciais) entra neste diretório — apenas o **nome do mecanismo** de unseal
quando o auto-unseal estiver ativo. Identificadores e endpoints chegam ao Pod do
Vault via `ExternalSecret` a partir do Vault/cofre do provider.

### Host CIDR no `networkPolicy.kubeApiCidrs`

`networkPolicy.kubeApiCidrs` em `values.yaml` inclui dois CIDRs:

| CIDR | Significado | Portátil? |
|---|---|---|
| `10.43.0.0/16` | Service CIDR default do K3s | Sim |
| `10.2.1.0/24` | Subnet OCI da VM k8s-host (sa-saopaulo-1, VCN `10.2.0.0/16`) | **Não** — substituir por cluster |

Por que dois CIDRs: o kube-router embutido do K3s avalia egress NetworkPolicy
*após* o DNAT do kube-proxy. Ao conectar `10.43.0.1:443` (Service IP do K8s API),
o destino é reescrito para `<node-ip>:6443` (em K3s o API server é processo no
host, não Pod). Sem o CIDR do nó na lista, ESO controller, ESO cert-controller e
cert-manager-cainjector entram em CrashLoopBackOff com
`dial tcp 10.43.0.1:443: connect: connection refused` no `init()`. PR #111 / issue #110.

Para registrar um cluster em outro host, identificar o CIDR real do nó
(`ip -4 addr show | awk '/inet 10\./ {print $2}'`) e substituir `10.2.1.0/24` em
`values.yaml` pela subnet observada. Em Tofu, o CIDR é output da network
(`provisioning/oci/standalone-compact/`) — derivar de lá em vez de hardcode.

## Como o ApplicationSet aplica

`argocd/applicationset.yaml` é genérico via label `environment: <env>`. Para o
ArgoCD reconciliar este overlay, registrar o cluster com:

```bash
argocd cluster add <kube-context> \
  --name uniplus-standalone-compact \
  --label uniplus.io/managed=true \
  --label environment=standalone-compact
```

O cluster vivo (`in-cluster`) já está registrado com esses labels. Procedimento
detalhado em `docs/RUNBOOKS.md` §8.

## Bootstrap

1. `tofu apply` em `provisioning/oci/standalone-compact/` (cria VMs/rede/DNS/volume).
2. Rodar o bootstrap **manualmente via SSH** em cada VM (sem cloud-init ainda — issue #387):
   - `./scripts/bootstrap-standalone.sh --role=standalone-k8s` no `k8s-host`
   - `./scripts/bootstrap-standalone.sh --role=standalone-data` no `data-host`
3. `./scripts/validate-standalone.sh` para sanidade.
4. Registrar o cluster no ArgoCD (acima).
5. Vault init + unseal Shamir + seed de secrets (passos manuais — ver
   `docs/REPRODUCIBILITY.md`, issues #384 e #385 para automação futura).

## Documentos relacionados

- [ADR-008 — Topologia standalone](../../docs/adrs/ADR-008-topologia-standalone.md)
- [docs/RUNBOOKS.md §8](../../docs/RUNBOOKS.md) — bootstrap e teardown
- [docs/REPRODUCIBILITY.md](../../docs/REPRODUCIBILITY.md) — recriar o ambiente do zero
- [docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) — visão arquitetural
