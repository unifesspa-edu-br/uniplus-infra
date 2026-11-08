# Scripts

Scripts de operação do ambiente `uniplus-prd` (duas VMs: aplicação e infraestrutura).

| Script | Função |
|--------|--------|
| `validate-rfc1123.py` | Valida nomes RFC 1123 em todos os charts (consumido pelo CI) |

## `servicos-no-host/`

Rodam nas VMs, todos aceitam `--dry-run` e leem `AMBIENTE` (`prd` por padrão, `hml` também é aceito). Os caminhos no Vault seguem [docs/vault-caminhos.md](../docs/vault-caminhos.md).

| Script | Onde roda | Função |
|--------|-----------|--------|
| `bootstrap-infra.sh` | VM de infraestrutura | PostgreSQL, Redis, MinIO, Kafka e RabbitMQ em containers sob systemd, só com TLS |
| `bootstrap-app.sh` | VM de aplicação | K3s, Helm, ArgoCD, Secret TLS, registro do cluster na revisão e ApplicationSets |
| `atualizar-producao.sh` | VM de aplicação | Aponta a produção para uma tag e reaplica ApplicationSets e verificador |
| `primeiro-sync.sh` | VM de aplicação | Primeiro sync, em dois tempos (Job de migration desligado na primeira operação) |
| `renovar-certificado.sh` | As duas VMs | Troca o certificado curinga e reinicia o que o usa |
| `configurar-vault.sh` | Qualquer máquina com o token raiz | KV por sistema, autenticação Kubernetes, política e role por sistema |
| `semear-vault.sh` | VM de infraestrutura | Grava no Vault os segredos que nascem na infraestrutura |
| `provisionar-bancos.sh` | VM de infraestrutura | Roles e bancos das aplicações, com a senha guardada no Vault |
| `provisionar-kafka.sh` | VM de infraestrutura | Tópico, usuário SCRAM e ACL do registro de acesso |
| `provisionar-rabbitmq.sh` | VM de infraestrutura | Vhost e usuários da verificação |
| `provisionar-verificacao.sh` | VM de infraestrutura | Transit, KES e credenciais da cifra dos arquivos do candidato |
| `provisionar-arquivos-candidato.sh` | VM de infraestrutura | Buckets, SSE-KMS e políticas dos arquivos do candidato no MinIO |
| `instalar-kafka.sh`, `instalar-minio.sh`, `instalar-redis.sh` | VM de infraestrutura | Instalação de cada serviço, chamada pelo `bootstrap-infra.sh` |

As bibliotecas `lib-*.sh` são carregadas por `source`. Ordem e contexto de uso: [docs/RUNBOOKS.md](../docs/RUNBOOKS.md).
