# ADR-003: Gov.br federado via OIDC institucional

- **Status:** ✅ Aceito
- **Data:** 2026-04-20
- **Relacionado:** [Issue #19](https://github.com/unifesspa-edu-br/uniplus-infra/issues/19)

## Contexto

A plataforma Uni+ exige um provedor de identidade seguro para candidatos e servidores. Como sistema de uma instituição federal, deve seguir as diretrizes de uso do login único do Governo Federal (Gov.br). Além disso, a UNIFESSPA precisa manter a governança sobre os metadados de identidade e papéis (roles) específicos do sistema.

## Alternativas consideradas

1. **Integração direta com Gov.br por aplicação:** Cada app Uni+ falaria diretamente com o IdP Gov.br.
   - ❌ Rejeitada: dispersa configuração de cliente OIDC, dificulta gestão de roles institucionais e auditoria unificada.
2. **OIDC institucional local em cada DC, sem federação Gov.br:** UNIFESSPA operaria o IdP autônomo.
   - ❌ Rejeitada: descumpre Decreto nº 10.543/2020 (Gov.br como padrão federal); reintroduz cadastro próprio.
3. **OIDC institucional federado com Gov.br, replicado nos 3 DCs:** UNIFESSPA opera o broker que delega ao Gov.br e enriquece com LDAP institucional.
   - ✅ Escolhida.

## Decisão

Federar o **Gov.br** através do contrato OIDC institucional da UNIFESSPA.

O serviço OIDC é executado de forma redundante nos três DCs (`SP1`, `SP2` e `PA1`). O DC institucional `PA1` mantém a origem institucional (`pa1-oidc-source`) e o LDAP, mas as instâncias operacionais em `SP1` e `SP2` devem ser capazes de processar o login via Gov.br mesmo que o link com `PA1` esteja temporariamente indisponível.

A implementação atual utiliza Keycloak, mas a arquitetura baseia-se no contrato padrão OIDC.

## Consequências

- ✅ **Conformidade legal:** Atendimento ao Decreto nº 10.543/2020.
- ✅ **Experiência do usuário:** Uso de uma identidade já conhecida (Gov.br) com suporte a 2FA.
- ✅ **Governança:** Centralização da gestão de permissões e auditoria na infraestrutura da UNIFESSPA.
- ✅ **Alta disponibilidade:** A operação distribuída do serviço OIDC nos 3 DCs evita que `PA1` seja ponto único de falha do login principal — o fluxo normal de autenticação via Gov.br continua operacional em `SP1`/`SP2` quando `PA1` está offline.
- ⚠️ **Degradação parcial sem PA1:** A indisponibilidade de `PA1` degrada apenas a sincronização institucional via LDAP (enriquecimento de dados de alunos/servidores), não o fluxo de login Gov.br em si.
