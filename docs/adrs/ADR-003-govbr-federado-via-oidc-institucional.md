# ADR 0003: Gov.br federado via OIDC institucional

- **Status:** ✅ Aceito
- **Data:** 2026-04-20
- **Relacionado:** [Issue #19](https://github.com/unifesspa-edu-br/uniplus-infra/issues/19)

## Contexto

A plataforma Uni+ exige um provedor de identidade seguro para candidatos e servidores. Como sistema de uma instituição federal, deve seguir as diretrizes de uso do login único do Governo Federal (Gov.br). Além disso, a UNIFESSPA precisa manter a governança sobre os metadados de identidade e papéis (roles) específicos do sistema.

## Decisão

Federar o **Gov.br** através do contrato OIDC institucional da UNIFESSPA. 

O serviço OIDC será executado de forma redundante nos três DCs (`SP1`, `SP2` e `PA1`). O DC institucional `PA1` mantém a origem institucional (`pa1-oidc-source`) e o LDAP, mas as instâncias operacionais em `SP1` e `SP2` devem ser capazes de processar o login via Gov.br mesmo que o link com `PA1` esteja temporariamente indisponível.

A implementação atual utiliza Keycloak, mas a arquitetura baseia-se no contrato padrão OIDC.

## Consequências

- ✅ **Conformidade Legal:** Atendimento ao Decreto nº 10.543/2020.
- ✅ **Experiência do Usuário:** Uso de uma identidade já conhecida (Gov.br) com suporte a 2FA.
- ✅ **Governança:** Centralização da gestão de permissões e auditoria na infraestrutura da UNIFESSPA.
- ✅ **Alta Disponibilidade:** A operação distribuída do serviço OIDC evita que o login seja um ponto único de falha.
- ⚠️ **Dependência LDAP:** O enriquecimento de dados via LDAP institucional (alunos/servidores) fica degradado se `PA1` estiver offline, embora o login via Gov.br continue funcional.
