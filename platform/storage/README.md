# storage

StorageClass nomeada por ambiente para a plataforma Uni+.

## Propósito

PVCs dos charts de plataforma (Vault, Vault Transit, Postgres-on-K8s, Prometheus, Loki, Tempo, Grafana) referenciam uma `StorageClass` por nome no campo `dataStorage.storageClass` ou equivalente. Este chart cria essa StorageClass em cada cluster, com nome alinhado ao **tier** do ambiente:

| Tier | Nome | Provisioner | Onde |
|------|------|-------------|------|
| Lab | `lab-local-nvme` | `rancher.io/local-path` (K3s default) | NVMe local nas máquinas Ryzen 9950X e i7 |
| Sanidade | `san-local-nvme` | `rancher.io/local-path` | NVMe local no DC institucional UNIFESSPA |
| Standalone | `standalone-local-nvme` | `rancher.io/local-path` | NVMe local na VM `k8s-host` (single-DC, ADR-008) |
| HML | `hml-local-nvme` | TBD (DIRSI) | Hardware EVEO/Unifesspa |
| Produção | `prod-local-nvme` | TBD (DIRSI) | Hardware EVEO/Unifesspa |

Em hml/prod, a escolha final do provisioner (local-path vs CSI driver dedicado — NetApp, Longhorn, etc.) é decisão da DIRSI durante a fase de promoção. O nome da StorageClass permanece estável (`prod-local-nvme`) para minimizar churn nos values dos demais charts.

O tier **standalone** (ADR-008) usa `reclaimPolicy: Delete` em vez do default `Retain` — o ambiente é monolocal e descartável (re-bootstrap via Tofu re-cria os PVs), e o `Retain` acumularia PVs órfãos. O override é injetado pelo overlay `environments/standalone/values.yaml`, introduzido em #73 (PR [#95](https://github.com/unifesspa-edu-br/uniplus-infra/pull/95)).

## Por que nome explícito por tier?

Sem nome explícito, os charts cairiam na StorageClass default do cluster (em K3s, `local-path`). Isso quebra dois objetivos:

1. **Auditabilidade**: qual SC está sendo usada por quê fica implícito.
2. **Promoção entre fases**: se prod usa um CSI driver diferente do default do K3s, o values precisa apontar explicitamente.

Nomes alinhados ao tier (`<tier>-local-nvme`) deixam claro de longe qual SC esperar em qual cluster e tornam óbvio quando alguém esquece de definir.

## Variáveis principais

| Caminho | Default | Descrição |
|---------|---------|-----------|
| `storage.enabled` | `true` | Liga/desliga a criação da SC. |
| `storage.storageClass.name` | `local-nvme` | **Override obrigatório por environment** com `lab-local-nvme`, `san-local-nvme`, `standalone-local-nvme`, `hml-local-nvme` ou `prod-local-nvme`. |
| `storage.storageClass.isDefault` | `true` | Marca a SC como default do cluster (`storageclass.kubernetes.io/is-default-class`). |
| `storage.storageClass.provisioner` | `rancher.io/local-path` | Provisioner. Override em hml/prod conforme decisão da DIRSI. |
| `storage.storageClass.volumeBindingMode` | `WaitForFirstConsumer` | Evita binding prematuro do PVC a um nó. |
| `storage.storageClass.reclaimPolicy` | `Retain` | Preserva dados ao deletar PVC (importante para Vault, Postgres). |
| `storage.storageClass.allowVolumeExpansion` | `true` | Permite resize de PVC. |
| `storage.storageClass.parameters` | `{}` | Parâmetros específicos do provisioner (CSI). |

## Dependências

- **K3s** (lab/sanidade): `local-path-provisioner` instalado por default — nada extra.
- **HML/Prod**: o provisioner escolhido pela DIRSI precisa ter seu Operator/CSI driver instalado antes deste chart sincronizar.

## Como o ApplicationSet aplica

O segundo `ApplicationSet` em `argocd/applicationset.yaml` (`uniplus-platform`) inclui `- component: storage`. Cada cluster registrado no ArgoCD gera uma Application correspondente que cria a StorageClass naquele cluster usando o nome do environment.

Como StorageClass é um recurso cluster-scoped, cada cluster tem **sua própria** SC, mesmo que o nome seja idêntico em clusters do mesmo tier.

## Test plan

```bash
# Renderiza para lab-sp1
helm template storage platform/storage/ -f environments/lab-sp1/values.yaml

# Esperado: 1 StorageClass com nome lab-local-nvme, isDefault=true,
# provisioner=rancher.io/local-path
```

Após sync no cluster:

```bash
kubectl --context uniplus-lab-sp1 get sc
# NAME            PROVISIONER            RECLAIMPOLICY  ...
# lab-local-nvme  rancher.io/local-path  Retain         ...
```

## Próximos passos

- **Sub-issue futura**: suportar lista de StorageClasses por cluster (ex.: uma SC para NVMe rápido + outra para SAN compartilhado).
- **DIRSI**: validar a escolha de provisioner em hml/prod e atualizar este chart conforme decisão.
