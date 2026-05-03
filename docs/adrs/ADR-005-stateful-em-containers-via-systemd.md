# ADR 0005: Stateful em containers via systemd

- **Status:** ✅ Aceito
- **Data:** 2026-04-20
- **Relacionado:** [Issue #21](https://github.com/unifesspa-edu-br/uniplus-infra/issues/21)

## Contexto

Uma vez decidido que PostgreSQL, Kafka e MinIO rodarão fora do Kubernetes (ADR 0002), precisamos escolher a forma de empacotamento: instalação direta no host (bare-metal) ou uso de containers (Docker/Podman) gerenciados pelo sistema operacional.

## Decisão

Utilizar **containers gerenciados pelo systemd**, com volumes mapeados em partições LVM dedicadas no NVMe local.

## Justificativa

- **Isolamento de Versão:** Permite rodar versões específicas de cada banco sem conflitos de dependências com as bibliotecas do host (Ubuntu 24.04).
- **Facilidade de Upgrade/Rollback:** Atualizar um componente resume-se a alterar a tag da imagem no unit file do systemd e reiniciar o serviço.
- **Paridade entre Ambientes:** O mesmo artefato (imagem de container) é usado em desenvolvimento, laboratório e produção.
- **Gerenciamento Familiar:** O systemd garante que o container suba no boot e seja reiniciado em caso de falha, usando ferramentas conhecidas pelo time de infra (`systemctl`, `journalctl`).

## Consequências

- ✅ **Portabilidade:** Facilita a migração para novos servidores físicos no futuro.
- ✅ **Higiene do Host:** O sistema operacional permanece "limpo", sem binários de banco ou messageria espalhados.
- ⚠️ **Overhead Mínimo:** Existe um custo computacional desprezível de virtualização de rede/processo, irrelevante frente aos ganhos de gestão.
- ⚠️ **Monitoramento:** Exige que o monitoramento colete métricas tanto do Docker/Podman quanto dos processos internos dos containers.
