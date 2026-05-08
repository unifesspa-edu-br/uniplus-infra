# minio-console-proxy

Proxy K8s para o MinIO Console externo (rodando como systemd no data-host). Apenas Service ExternalName + IngressRoute Traefik + Certificate cert-manager — **sem workload K8s**.

## Quando usar

Ative em ambientes que precisam expor o MinIO Console publicamente (UI admin do MinIO acessível por browser sem SSH tunnel). Em standalone, MinIO API S3 (port 9000) NÃO é exposto pelo proxy: clients S3 falam direto com o IP privado do data-host via subnet privada VCN.

## Pré-requisitos

| Recurso | De onde vem |
|---|---|
| MinIO Console rodando no data-host | systemd `uniplus-minio` (port 9001) |
| cert-manager + ClusterIssuer LE prod | `platform/cert-manager/` |
| Traefik com entryPoint `websecure` | `platform/traefik/` |
| DNS público | CNAME `minio.<env>.<dominio>` → `<env>.<dominio>` |

## Auth

MinIO Console tem login próprio com root user/pwd custodiado em Vault `secret/standalone/minio/root`. Não há OIDC SSO configurado neste chart — para hml/prod considerar OpenID provider config nativo do MinIO server (`MINIO_IDENTITY_OPENID_*`).

## Operação

Procedimentos detalhados em `docs/RUNBOOKS.md` §12.7 (acesso público via Console).
