#!/usr/bin/env python3
"""Lê e escreve as tags de imagem num values.yaml, sem perder comentários.

A leitura usa o parser de YAML — `yaml.compose` devolve a árvore de nós com a marca
de posição de cada um, o que dá a linha exata do escalar. Percorrer o arquivo com
expressão regular por indentação pareceria funcionar e quebraria na primeira
construção válida que não estivesse prevista: comentário inline, aspas, âncora,
bloco literal.

A escrita substitui **aquela linha**, e só ela. Reserializar o documento apagaria os
comentários que explicam cada pin, que é a parte do values com mais valor para quem
lê depois.
"""

from __future__ import annotations

import yaml


class ChaveNaoEncontrada(LookupError):
    """O caminho pedido não existe no documento."""


def _no_do_caminho(raiz: yaml.Node, caminho: list[str]) -> yaml.ScalarNode:
    atual: yaml.Node = raiz
    for parte in caminho:
        if not isinstance(atual, yaml.MappingNode):
            raise ChaveNaoEncontrada(f"'{parte}' não está sob um mapeamento")
        for chave, valor in atual.value:
            if isinstance(chave, yaml.ScalarNode) and chave.value == parte:
                atual = valor
                break
        else:
            raise ChaveNaoEncontrada(parte)
    if not isinstance(atual, yaml.ScalarNode):
        raise ChaveNaoEncontrada(f"{'.'.join(caminho)} não é um valor escalar")
    return atual


def _quantas_vezes_aparece(raiz: yaml.Node, alvo: yaml.Node) -> int:
    """Quantas posições da árvore referenciam o MESMO nó (identidade, não igualdade).

    Mais de uma significa âncora compartilhada: `yaml.compose` devolve um único nó para
    a âncora e para cada alias que a referencia.
    """
    total = 0
    pilha = [raiz]
    while pilha:
        no = pilha.pop()
        if no is alvo:
            total += 1
        if isinstance(no, yaml.MappingNode):
            pilha.extend(valor for _, valor in no.value)
            pilha.extend(chave for chave, _ in no.value)
        elif isinstance(no, yaml.SequenceNode):
            pilha.extend(no.value)
    return total


def ler(values: str, caminho: str) -> str:
    """Valor escalar em `caminho` (ex.: `uniplusApiHost.image.tag`)."""
    raiz = yaml.compose(values)
    if raiz is None:
        raise ChaveNaoEncontrada("documento vazio")
    return _no_do_caminho(raiz, caminho.split(".")).value


def escrever(values: str, caminho: str, novo_valor: str) -> str:
    """Troca o valor em `caminho`, preservando o resto do arquivo intacto.

    A troca é dirigida pela **chave**, não pelo valor: várias chaves compartilham a
    mesma tag, e casar pelo valor mudaria todas de uma vez.
    """
    raiz = yaml.compose(values)
    if raiz is None:
        raise ChaveNaoEncontrada("documento vazio")

    no = _no_do_caminho(raiz, caminho.split("."))

    # Pin ancorado ou vindo de alias é recusado. `yaml.compose` resolve o alias e
    # devolve o nó ANCORADO, cujas marcas apontam para a declaração da âncora — e não
    # para o ponto onde o alias aparece. Escrever ali trocaria o valor compartilhado,
    # mudando de tabela outras tags que ninguém pediu para promover. É o oposto exato
    # da garantia deste módulo, que é a troca ser dirigida pela chave.
    if _quantas_vezes_aparece(raiz, no) > 1:
        raise ChaveNaoEncontrada(
            f"{caminho} usa âncora ou alias de YAML, e o valor é compartilhado com "
            "outra chave; promover aqui mudaria as duas. Escreva a tag literal."
        )

    if no.end_mark.line != no.start_mark.line:
        # Escalar em mais de uma linha (bloco literal, dobrado, quebra em aspas). Não
        # ocorre com tag de imagem, e recortar pela coluna comeria o resto do arquivo.
        raise ChaveNaoEncontrada(f"{caminho} ocupa mais de uma linha; não é uma tag")

    linhas = values.split("\n")
    indice = no.start_mark.line
    linha = linhas[indice]

    # Repõe o estilo de aspas que estava lá. Sem isto, um pin escrito como
    # `tag: "v0.7.0"` voltaria sem aspas — YAML igualmente válido, mas um diff que
    # mexe no que ninguém pediu para mexer.
    aspas = no.style if no.style in ('"', "'") else ""
    inicio, fim = no.start_mark.column, no.end_mark.column
    linhas[indice] = linha[:inicio] + aspas + novo_valor + aspas + linha[fim:]
    resultado = "\n".join(linhas)

    # Relê antes de devolver. A troca é cirúrgica de propósito, e o preço de ser
    # cirúrgica é não ter o parser conferindo o resultado — este passo devolve essa
    # conferência, e transforma qualquer caso de borda não previsto em erro em vez de
    # values corrompido.
    if ler(resultado, caminho) != novo_valor:
        raise ChaveNaoEncontrada(f"a troca em {caminho} não produziu {novo_valor}")
    return resultado
