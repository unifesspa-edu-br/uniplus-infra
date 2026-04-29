# Política de Segurança

Levamos a segurança da infraestrutura do Uni+ a sério. Por se tratar de plataforma institucional federal que processará dados pessoais sob a LGPD, vulnerabilidades têm impacto potencial significativo.

## Versões suportadas

Este repositório possui apenas a branch principal (`main`) como versão suportada. Não há versões legadas em manutenção.

## Reportando uma vulnerabilidade

**Não abra Issues públicas para vulnerabilidades de segurança.**

Para reportar:

1. Envie e-mail para: **`jeferson.ferreira@unifesspa.edu.br`** com cópia para `ctic@unifesspa.edu.br`
2. Assunto: `[SECURITY] uniplus-infra — <descrição curta>`
3. Inclua no corpo:
   - Descrição da vulnerabilidade
   - Componente afetado
   - Passos para reproduzir
   - Impacto potencial
   - Sugestão de correção (se houver)

## O que esperar

| Etapa | Prazo |
|-------|-------|
| Confirmação de recebimento | até 2 dias úteis |
| Triagem inicial | até 5 dias úteis |
| Resposta sobre validade e plano de ação | até 10 dias úteis |
| Correção (vulnerabilidade crítica) | até 30 dias |
| Correção (vulnerabilidade alta) | até 60 dias |
| Correção (vulnerabilidade média/baixa) | conforme priorização |

## Escopo

Vulnerabilidades neste repositório, incluindo:

- Manifests Kubernetes que exponham serviços indevidamente
- Configurações de RBAC excessivamente permissivas
- Charts Helm com defaults inseguros
- Scripts que vazem credenciais
- Documentação que oriente práticas inseguras

**Não estão no escopo:**

- Vulnerabilidades em dependências de terceiros (reporte ao mantenedor original)
- Vulnerabilidades em sistemas em produção operados pelo CTIC (reporte direto via canal interno)
- Engenharia social, físico, ou pessoal

## Reconhecimento

Pesquisadores que reportarem vulnerabilidades válidas serão reconhecidos publicamente (com permissão) após a correção, através de:

- Menção no [CHANGELOG.md](CHANGELOG.md)
- Issue/PR de agradecimento (sem detalhes da vulnerabilidade)

## Compromisso

A UNIFESSPA se compromete a:

- Tratar todas as comunicações com confidencialidade
- Manter o reportador informado sobre o progresso
- Não tomar ações legais contra reportadores que ajam de boa-fé
- Coordenar divulgação responsável após a correção

---

*Documento alinhado com a [Lei Geral de Proteção de Dados (LGPD)](http://www.planalto.gov.br/ccivil_03/_ato2015-2018/2018/lei/l13709.htm) e práticas de divulgação coordenada de vulnerabilidades.*
