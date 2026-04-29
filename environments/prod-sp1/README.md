# Environment: prod-sp1

Valores específicos para o ambiente `prod-sp1`.

Veja `values.yaml` neste diretório para configuração detalhada.

## Como usar

Este values é referenciado pelo ApplicationSet do ArgoCD em `argocd/applicationset.yaml` para gerar Applications específicas para este ambiente.

Não execute helm install manualmente neste values — deixe o ArgoCD gerenciar.

## Cluster alvo

Veja `docs/SETUP.md` para detalhes sobre como provisionar o cluster correspondente.
