# ADR-019: Aplicações comparam pelo cliente no ArgoCD

- **Status:** ✅ Aceito
- **Data:** 2026-11-28
- **Issue:** [#850](https://github.com/unifesspa-edu-br/uniplus-infra/issues/850)
- **Relacionado:** [ADR-006](ADR-006-gitops-com-argocd.md) · [ADR-017](ADR-017-producao-aplicada-pelo-pipeline-na-vm-de-automacao.md)

## Contexto

O ArgoCD compara o que está no Git com o que está no cluster. O `bootstrap-app.sh` liga a comparação feita pelo servidor (`controller.diff.server.side`) para todas as Applications, porque a comparação local quebrava com a versão do K3s em uso. A plataforma é aplicada pelo servidor, então os dois modos combinam.

As aplicações (APIs, web, Geo, verificador) são aplicadas pelo cliente. Em um recurso criado dessa forma, os itens de lista pertencem ao gerenciador antigo. A comparação pelo servidor não é dona desses itens e não enxerga a remoção deles: o chart do host passou de oito connection strings para uma e a Application seguiu "Synced" com as oito.

## Alternativas consideradas

- **Só regra de processo** (subir a versão do chart quando o conteúdo remover campo): depende de alguém lembrar; fica como saída de emergência.
- **Aplicar as aplicações pelo servidor:** a versão 2.14 do ArgoCD não transfere o dono dos campos antigos; reavaliar na versão 3.
- **Desligar a comparação pelo servidor para todos:** traz de volta o erro de comparação da plataforma.

## Decisão

Cada grupo compara do mesmo modo em que é aplicado. A plataforma segue aplicando e comparando pelo servidor. As Applications das aplicações têm a anotação `argocd.argoproj.io/compare-options: ServerSideDiff=false`, definida nos ApplicationSets e no `verificador.yaml` do repositório de implantação.

## Consequências

- A remoção de itens de lista volta a aparecer na comparação, sem precisar subir a versão do chart.
- Ao comparar do modo certo, aplicações em produção podem mostrar diferenças antigas que estavam escondidas. Cada uma é revista antes do sync, que segue um componente por vez (ADR-017).
- Revisar esta decisão quando o ArgoCD for atualizado para a versão 3.
