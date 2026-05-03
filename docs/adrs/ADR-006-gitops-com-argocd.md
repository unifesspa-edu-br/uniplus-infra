# ADR-006: GitOps com ArgoCD

- **Status:** ✅ Aceito
- **Data:** 2026-04-20
- **Relacionado:** [Issue #16](https://github.com/unifesspa-edu-br/uniplus-infra/issues/16)

## Contexto

A gestão de múltiplos clusters Kubernetes (`SP1` e `SP2`) exige uma forma automatizada e auditável de garantir que o estado das aplicações e da infraestrutura (Helm charts, manifests) seja idêntico e livre de intervenções manuais que causem desvios (drifts).

## Alternativas consideradas

1. **Push pipeline (Jenkins/GitHub Actions aplicando `kubectl`/`helm` direto):** CI roda contra cada cluster.
   - ❌ Rejeitada: não detecta drift introduzido fora do pipeline; credencial de admin precisa estar no CI; reconciliação não é contínua.
2. **GitOps com Flux:** Controller in-cluster reconciliando o git.
   - ⚖️ Considerada: alternativa válida, mas o time já tem familiaridade operacional com a UI e o modelo de Application/ApplicationSet do ArgoCD.
3. **GitOps com ArgoCD:** Controller in-cluster com `ApplicationSet` por cluster + caminho.
   - ✅ Escolhida.

## Decisão

Adotar a prática de **GitOps utilizando o ArgoCD** em cada cluster.

Utilizaremos o padrão `ApplicationSet` para gerar automaticamente as aplicações do ArgoCD a partir de geradores baseados em clusters e caminhos no repositório git. Todo o estado declarativo da plataforma deve residir no Git.

## Consequências

- ✅ **Auditoria:** Todo histórico de mudanças na infraestrutura está registrado no histórico do Git.
- ✅ **Recuperação rápida:** Em caso de desastre do cluster, o ArgoCD pode reprovisionar todos os serviços a partir do repositório em poucos minutos.
- ✅ **Consistência:** Redução drástica de erros causados por `kubectl apply` manuais ou esquecimentos em um dos DCs.
- ⚠️ **Curva de aprendizado:** Exige que o time de desenvolvimento e operação se familiarize com o fluxo de Pull Request para qualquer mudança de infraestrutura.
- ⚠️ **Segurança:** O repositório Git torna-se o ponto crítico de segurança; segredos devem ser gerenciados via External Secrets/Vault e nunca commitados em texto claro.
