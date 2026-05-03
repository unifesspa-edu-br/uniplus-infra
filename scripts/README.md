# Scripts

Scripts auxiliares para setup, validação e teardown do laboratório.

| Script | Função |
|--------|--------|
| `bootstrap-lab.sh` | Provisiona laboratório do zero em uma máquina Linux |
| `validate-cluster.sh` | Valida saúde do cluster (use após bootstrap ou para diagnóstico) |
| `teardown-lab.sh` | Remove o laboratório (CUIDADO: destrutivo) |

## Uso

```bash
# Tornar executáveis (uma vez)
chmod +x scripts/*.sh

# Bootstrap da máquina principal (Ryzen)
./scripts/bootstrap-lab.sh --role=sp1

# Bootstrap da máquina secundária (i7)
./scripts/bootstrap-lab.sh --role=sp2

# Bootstrap do DC institucional UNIFESSPA simulado (cluster K3s + containers Docker, no host i7)
./scripts/bootstrap-lab.sh --role=pa1

# Com Cloudflare Tunnel
./scripts/bootstrap-lab.sh --role=sp1 --enable-cloudflared

# Modo dry-run (apenas mostra o que seria feito)
./scripts/bootstrap-lab.sh --role=sp1 --dry-run

# Validar cluster após bootstrap
./scripts/validate-cluster.sh

# Tear down (cuidado!)
./scripts/teardown-lab.sh
```

## Roadmap de scripts adicionais

Conforme o lab evoluir, planejamos adicionar:

- [ ] `chaos/kill-postgres-primary.sh` — Cenário 3 do VALIDATION-PLAN
- [ ] `chaos/network-partition.sh` — Cenário 4 (split-brain)
- [ ] `chaos/dc-down.sh` — Cenário 5 (DC inteiro fora)
- [ ] `load-test/k6-edital-peak.js` — Cenário 8 (carga em pico)
- [ ] `backup/test-restore.sh` — Cenário 12 (backup/restore)
