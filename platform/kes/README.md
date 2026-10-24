# kes

KES (Key Encryption Service) do MinIO para o SSE-KMS dos arquivos do candidato
([ADR-0146](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0146-cifra-e-verificacao-dos-arquivos-do-candidato-no-armazenamento.md)
do uniplus-api, issue `uniplus-infra#682`).

## Como funciona

```text
MinIO (host, systemd) ──mTLS :7373 (hostPort)──▶ KES (pod) ──Kubernetes auth──▶ Vault
                                                              KV secret/kes/*  (chaves mestras, cifradas)
                                                              transit/uniplus-kes-kek (cifra cada chave)
```

- A chave mestra `uniplus-arquivos-candidato` fica no KV do Vault, cifrada pela
  chave Transit `uniplus-kes-kek`. Cada objeto recebe uma chave de dados própria.
- O KES autentica no Vault pela ServiceAccount `kes` (namespace `kes`), na role
  `kes`, com política mínima.
- Duas identidades na política do KES:
  - `minio`: `generate`, `decrypt` e `bulk/decrypt` da chave dos arquivos, mais `/v1/status` e a listagem restrita a essa chave;
  - `provisioner`: só cria e descreve a chave, uma vez. A chave de API dela nunca
    vai ao MinIO.
- Cache de 30 s (`any`) e sem cache offline: o Vault selado ou a chave revogada
  derrubam a leitura e a gravação em segundos (falha fechada).

## O que o chart não faz

Escrever no Vault. A chave Transit, a política, a role, o certificado do servidor
e as identidades são criados por
`scripts/hml-standalone-single/provision-verificacao-prerequisites.sh`; o ExternalSecret
do chart lê o resultado em `secret/standalone/kes/server` e
`secret/standalone/kes/identities`.

## Valores principais

| Chave | Descrição |
|---|---|
| `kes.enabled` | Liga o chart (default `false`). |
| `kes.vault.address` | Service do Vault. Obrigatório quando ligado. |
| `kes.hostPort` | Porta em que o MinIO alcança o KES (7373). |
| `kes.keyName` | Chave mestra (`uniplus-arquivos-candidato`). |
| `kes.cache.*` | Expiração do cache (disponibilidade x revogação). |
| `kes.networkPolicy.hostCidrs` | Origens do host autorizadas no hostPort. |

Operação e provisionamento: `docs/RUNBOOKS.md` §21.9.
