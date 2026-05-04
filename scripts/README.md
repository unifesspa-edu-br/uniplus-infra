# Scripts

Scripts de operação do laboratório e do ambiente standalone OCI.

| Script | Função |
|--------|--------|
| `bootstrap-lab.sh` | Provisiona o laboratório do zero em uma máquina Linux (roles sp1/sp2/pa1) |
| `bootstrap-standalone.sh` | Provisiona o ambiente standalone OCI (roles standalone-k8s e standalone-data) |
| `validate-cluster.sh` | Valida saúde do cluster de laboratório (sp1/sp2/pa1) |
| `validate-standalone.sh` | Valida saúde do ambiente standalone OCI (k8s-host + data-host) |
| `teardown-lab.sh` | Remove o laboratório ou standalone (CUIDADO: destrutivo) |

## Laboratório (sp1 / sp2 / pa1)

```bash
# Bootstrap da máquina principal (Ryzen — Arch Linux)
./scripts/bootstrap-lab.sh --role=sp1

# Bootstrap da máquina secundária (i7 — Ubuntu Server)
./scripts/bootstrap-lab.sh --role=sp2

# Bootstrap do DC institucional UNIFESSPA simulado (K3s + containers Docker)
./scripts/bootstrap-lab.sh --role=pa1

# Com Cloudflare Tunnel (requer login interativo)
./scripts/bootstrap-lab.sh --role=sp1 --enable-cloudflared

# Modo dry-run
./scripts/bootstrap-lab.sh --role=sp1 --dry-run

# Validar cluster
./scripts/validate-cluster.sh

# Teardown (cuidado!)
./scripts/teardown-lab.sh
```

## Standalone OCI (dois hosts Ubuntu)

Ambiente de homologação e produção inicial: um `k8s-host` (K3s + ArgoCD) e um
`data-host` (Docker + volumes LVM para Postgres, Kafka, MinIO, Vault e Redis).

### Bootstrap

```bash
# No k8s-host — K3s + Helm + ArgoCD
./scripts/bootstrap-standalone.sh --role=standalone-k8s

# No data-host — Docker + LVM + mount points
./scripts/bootstrap-standalone.sh --role=standalone-data

# Dry-run (mostra o que seria feito, sem executar)
./scripts/bootstrap-standalone.sh --role=standalone-k8s --dry-run
./scripts/bootstrap-standalone.sh --role=standalone-data --dry-run

# Flags disponíveis
#   --skip-k3s        Pula instalação do K3s (standalone-k8s)
#   --skip-docker     Pula instalação do Docker (standalone-data)
#   --enable-cloudflared  Inclui setup do Cloudflare Tunnel (standalone-k8s)
```

### Variáveis de ambiente (standalone-data)

O bootstrap do data-host descobre os block volumes OCI automaticamente por
tamanho. Topologia esperada: 1 × 50 GB (Vault), 1 × 100 GB (Kafka),
2 × 200 GB (Postgres e MinIO). Verificar com `lsblk` antes de rodar.

### Validação

```bash
# No k8s-host (valida os dois hosts)
./scripts/validate-standalone.sh

# Sobrepor IP do data-host (padrão: 10.0.2.87)
DATA_HOST_IP=10.0.2.87 ./scripts/validate-standalone.sh
```

Saída esperada em ambiente completo: **`X OK, 0 ERROS, Y AVISOS`**.
Avisos são esperados enquanto serviços ainda não provisionados (Vault, dados).

### Teardown

```bash
# Teardown do k8s-host (desinstala K3s — dados do data-host preservados)
./scripts/teardown-lab.sh --role=standalone-k8s

# Teardown do data-host (para containers, desmonta LVM — dados nos block volumes preservados)
./scripts/teardown-lab.sh --role=standalone-data
```

## Roadmap

- [ ] `chaos/kill-postgres-primary.sh` — Cenário 3 do VALIDATION-PLAN
- [ ] `chaos/network-partition.sh` — Cenário 4 (split-brain)
- [ ] `chaos/dc-down.sh` — Cenário 5 (DC inteiro fora)
- [ ] `load-test/k6-edital-peak.js` — Cenário 8 (carga em pico)
- [ ] `backup/test-restore.sh` — Cenário 12 (backup/restore)
