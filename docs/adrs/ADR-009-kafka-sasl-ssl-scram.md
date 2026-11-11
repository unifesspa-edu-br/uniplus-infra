# ADR-009: Kafka com SASL_SSL, SCRAM-SHA-512 e StandardAuthorizer

- **Status:** ✅ Aceito
- **Data:** 2026-05-07 (reescrita para `uniplus-hml` e `uniplus-prd` em 2026-11-11)
- **Relacionado:** [Issue #138](https://github.com/unifesspa-edu-br/uniplus-infra/issues/138) · [Issue #786](https://github.com/unifesspa-edu-br/uniplus-infra/issues/786) · [ADR-005](ADR-005-stateful-em-containers-via-systemd.md) · [ADR-015](ADR-015-producao-em-duas-vms-com-tls-e-atualizacao-manual.md)

## Contexto

O Kafka roda fora do Kubernetes, em container sob systemd na VM de dados de `uniplus-hml` e de
`uniplus-prd` (ADR-005). Os eventos publicados podem carregar dados pessoais, e os serviços de dados
do Uni+ já autenticam por senha guardada no Vault. O broker precisa autenticar e cifrar o tráfego, e
negar o que não foi liberado.

## Decisão

1. **Listener `SASL_SSL`** nos dois ambientes, sem porta em texto claro. O `instalar-kafka.sh`
   instala o certificado do domínio quando informado (os clientes validam o nome) e, sem ele, gera
   um PEM autoassinado. Um par já instalado é preservado.
2. **Autenticação por `SCRAM-SHA-512`**, único mecanismo habilitado. Há um usuário `admin`, que
   também serve ao tráfego entre os nós do Kafka, e um usuário por aplicação.
3. **Autorização por `StandardAuthorizer`** (nativo do KRaft), em modo fechado
   (`allow.everyone.if.no.acl.found=false`) e com `super.users=User:admin`. Cada aplicação recebe só
   as ACLs de que precisa, sobre tópicos literais, nunca curingas globais.
4. **Custódia no Vault:** a senha de cada usuário e a CA do broker ficam no KV do sistema dono
   (`kafka/<usuário>` e `kafka/ca`), de onde o External Secrets as entrega ao pod. O mapa está em
   [vault-caminhos.md](../vault-caminhos.md). Os usuários e as ACLs das aplicações são criados por
   scripts de `scripts/servicos-no-host/` (hoje `provisionar-kafka.sh`, para o registro de acesso).

## Alternativas consideradas

- **Sem autenticação ou `SASL_PLAINTEXT`:** deixa a mensagem em claro na rede. Rejeitada.
- **TLS mútuo:** exige emissão e rotação de certificado por aplicação. Rejeitada.
- **`OAUTHBEARER` com o Keycloak:** acrescenta ao broker a dependência do JWKS do Keycloak e um
  ciclo de token por cliente, sem ganho sobre a senha SCRAM guardada no Vault. Rejeitada.

## Consequências

- Toda aplicação nova pede um usuário e as ACLs correspondentes antes de produzir ou consumir.
- Trocar a senha de um usuário exige atualizar o Vault e reiniciar quem a usa.
- Renovar o certificado do domínio reinicia o broker (ADR-015).
