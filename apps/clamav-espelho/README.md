# clamav-espelho

Espelho interno da base de assinaturas do ClamAV ([ADR-0147 do uniplus-api](https://github.com/unifesspa-edu-br/uniplus-api/blob/main/docs/adrs/0147-base-de-assinaturas-do-antivirus-por-espelho-interno.md)).

O `cvdupdate` baixa a base do CDN oficial a cada `intervaloHoras` e um nginx
a serve por HTTP dentro do cluster. O freshclam do clamd sidecar de cada pod do
verificador usa o Service como `PrivateMirror`. É o único componente da
verificação com saída para a internet.

## Endereço para o verificador

```text
http://clamav-espelho.<namespace>.svc.cluster.local
```

O nome do Service é fixo (`clamavEspelho.service.name`) e não herda o nome do
release. Em HML o namespace é `uniplus`.

## Relação com o chart `clamav-scanner`

O `apps/clamav-scanner` permanece enquanto a API host usa o clamd dele. Quando
o verificador da uniplus-api#2054 assumir a verificação (clamd como sidecar), o
`clamav-scanner` é removido (uniplus-infra#684).

## Arquivos servidos

- `main.cvd`, `daily.cvd` (ou `.cld`) e `bytecode.cvd`;
- `ultima-atualizacao`: epoch UTC da última atualização concluída com sucesso.

## Operação

Veja a seção do espelho do ClamAV em [docs/RUNBOOKS.md](../../docs/RUNBOOKS.md).
