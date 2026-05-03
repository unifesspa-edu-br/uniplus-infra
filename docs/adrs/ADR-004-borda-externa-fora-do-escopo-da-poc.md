# ADR 0004: Borda externa fora do escopo da PoC

- **Status:** 🟡 Pendente
- **Data:** 2026-04-20
- **Relacionado:** [Issue #20](https://github.com/unifesspa-edu-br/uniplus-infra/issues/20)

## Contexto

A exposição segura da plataforma exige componentes de borda como WAF (Web Application Firewall), proteção DDoS volumétrica, gerenciamento de DNS institucional e inspeção TLS profunda. Estes componentes costumam ser compartilhados com outros serviços da instituição ou exigem integrações específicas com provedores de rede.

## Decisão

A **PoC de engenharia** utilizará uma entrada HTTP/TLS provisória (ex: Túneis Cloudflare ou Ingress direto) para expor o ambiente de laboratório. 

A definição final da arquitetura de borda, incluindo escolha de WAF, topologia de IPSEC entre DCs e integração com o DNS oficial, fica pendente para uma etapa posterior, a ser validada pelo time de infraestrutura e rede da UNIFESSPA sobre a réplica mínima de produção.

## Consequências

- ✅ **Agilidade:** Permite o progresso da PoC de engenharia sem bloqueios por decisões de rede complexas.
- ✅ **Foco:** As evidências da PoC focarão em redundância, escalabilidade e recuperabilidade da aplicação.
- ⚠️ **Risco de Segurança:** O ambiente de laboratório não deve ser usado para dados reais sensíveis sem a borda definitiva.
- ⚠️ **Ajustes Futuros:** Mudanças na topologia de borda podem exigir ajustes finos nos Ingress Controllers (Traefik) futuramente.
