#!/usr/bin/env python3
"""Compara as tags publicadas no GHCR com as fixadas no values de um ambiente.

Existe porque a perna Git -> cluster já é automática (o ArgoCD reconcilia sozinho),
mas a anterior não era: descobrir que há imagem nova e escrever a tag no values era
100% manual, e foi por isso que homologação já ficou cinco semanas atrasada.

Consulta o registry de forma anônima, de propósito: as imagens são públicas, e assim
o workflow não precisa de segredo nenhum além do token que o próprio GitHub Actions
já fornece ao repositório.

A leitura do values usa o parser de YAML (ver `values_tags`), não varredura de texto.

Não escreve nada. Devolve o que mudou, em JSON, para quem chama decidir.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

import yaml

from values_tags import ChaveNaoEncontrada, ler

yaml_error = yaml.YAMLError

REGISTRY = "https://ghcr.io"
ORG = "unifesspa-edu-br"

# Cada imagem, o repositório que a publica e a chave que a fixa no values do ambiente.
# O caminho é literal porque é o que aparece no arquivo — resolver YAML aqui esconderia
# a ligação.
#
# A origem importa: as quatro imagens do web saem de um único release, e um release
# publica uma imagem de cada vez. Um ciclo que caia no meio veria parte já no registry
# e parte ainda na versão anterior. Ver `_agrupar_por_origem`.
IMAGENS = {
    "uniplus-api-host": ("uniplus-api", "uniplusApiHost.image.tag"),
    "uniplus-portal": ("uniplus-web", "uniplusWeb.apps.portal.tag"),
    "uniplus-web-selecao": ("uniplus-web", "uniplusWeb.apps.selecao.tag"),
    "uniplus-web-ingresso": ("uniplus-web", "uniplusWeb.apps.ingresso.tag"),
    "uniplus-web-configuracao": ("uniplus-web", "uniplusWeb.apps.configuracao.tag"),
}

# Só versões completas. O registry também publica `v0.7`, que é um alias móvel — e
# promover alias tiraria do values a capacidade de dizer exatamente o que está no ar.
SEMVER = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")


def _obter(url: str, cabecalhos: dict[str, str], timeout: int) -> dict:
    requisicao = urllib.request.Request(url, headers=cabecalhos)
    with urllib.request.urlopen(requisicao, timeout=timeout) as resposta:
        return json.load(resposta)


def listar_tags(imagem: str, timeout: int = 20) -> list[tuple[int, int, int]]:
    """Versões completas publicadas para a imagem, ordenadas da mais antiga à mais nova."""
    token = _obter(
        f"{REGISTRY}/token?scope=repository:{ORG}/{imagem}:pull&service=ghcr.io",
        {},
        timeout,
    )["token"]
    tags = _obter(
        f"{REGISTRY}/v2/{ORG}/{imagem}/tags/list",
        {"Authorization": f"Bearer {token}"},
        timeout,
    ).get("tags") or []
    return sorted(
        tuple(int(p) for p in m.groups())
        for t in tags
        if (m := SEMVER.match(t))
    )


def _agrupar_por_origem(desatualizadas: list[dict], em_dia: list[dict]) -> tuple[list[dict], list[dict]]:
    """Separa os bumps cujo grupo de origem ainda não concorda na versão.

    Um release publica uma imagem por vez. Um ciclo que caia no meio do release do web
    veria `uniplus-portal` já em v0.4.0 e as outras três ainda em v0.3.0, e proporia o
    values com versões misturadas do MESMO frontend — combinação que nunca foi
    construída junto, muito menos testada.

    O critério é o consenso dentro da origem: ou todas as imagens do repositório
    apontam para a mesma versão nova, ou nenhuma vai neste ciclo. Adiar custa dez
    minutos; promover misturado custa um ambiente num estado que ninguém montou de
    propósito.

    Origens diferentes seguem independentes: api e web têm ciclos próprios, e segurar
    uma porque a outra publicou seria inventar um acoplamento que não existe.
    """
    alvo_por_origem: dict[str, set[str]] = {}
    for item in desatualizadas + em_dia:
        alvo_por_origem.setdefault(item["origem"], set()).add(item["para"])

    promover, adiar = [], []
    for item in desatualizadas:
        if len(alvo_por_origem[item["origem"]]) > 1:
            adiar.append(item | {
                "motivo": (
                    f"o release de {item['origem']} ainda não publicou todas as imagens "
                    f"nesta versão: o registry mostra "
                    f"{', '.join(sorted(alvo_por_origem[item['origem']]))}"
                )
            })
        else:
            promover.append(item)
    return promover, adiar


def comparar(values: str, timeout: int = 20) -> dict:
    desatualizadas, erros, em_dia = [], [], []
    for imagem, (origem, chave) in IMAGENS.items():
        try:
            fixada = ler(values, chave)
        except (ChaveNaoEncontrada, yaml_error) as erro:
            erros.append({"imagem": imagem, "motivo": f"chave {chave} ilegível no values: {erro}"})
            continue
        try:
            publicadas = listar_tags(imagem, timeout)
        except (urllib.error.URLError, TimeoutError, ValueError, KeyError) as erro:
            # Falha de rede não pode virar PR incompleto nem quebrar o agendamento:
            # relata e deixa a decisão para quem chama.
            erros.append({"imagem": imagem, "motivo": f"consulta ao registry falhou: {erro}"})
            continue
        if not publicadas:
            erros.append({"imagem": imagem, "motivo": "nenhuma versão completa publicada"})
            continue

        # Comparação por ordem, e não por diferença. Tratar "diferente" como
        # "desatualizada" faria o ciclo propor rebaixar o ambiente sempre que a maior
        # tag do registry ficasse ATRÁS do pin — uma tag apagada, um registry
        # respondendo listagem parcial — e o texto ainda chamaria o retrocesso de
        # versão nova. Rebaixar homologação sem ninguém ter pedido é pior que não
        # promover nada.
        casa = SEMVER.match(fixada)
        if casa is None:
            erros.append({
                "imagem": imagem,
                "motivo": f"o values fixa '{fixada}', que não é uma versão completa vX.Y.Z",
            })
            continue

        atual = tuple(int(parte) for parte in casa.groups())
        maior_publicada = publicadas[-1]
        maior = "v" + ".".join(str(parte) for parte in maior_publicada)
        item = {"imagem": imagem, "origem": origem, "chave": chave, "de": fixada, "para": maior}

        if maior_publicada > atual:
            desatualizadas.append(item)
        elif maior_publicada == atual:
            em_dia.append(item)
        else:
            # Nada a promover, e nada que o ciclo deva decidir sozinho: ou a tag saiu
            # do registry, ou o values aponta para algo que nunca foi publicado.
            erros.append({
                "imagem": imagem,
                "motivo": (
                    f"o values fixa {fixada}, à frente da maior publicada ({maior}) — "
                    "promover seria rebaixar o ambiente; requer conferência"
                ),
            })
    desatualizadas, adiadas = _agrupar_por_origem(desatualizadas, em_dia)
    return {
        "desatualizadas": desatualizadas,
        "em_dia": em_dia,
        "adiadas": adiadas,
        "erros": erros,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--values", required=True, help="values.yaml do ambiente")
    parser.add_argument("--timeout", type=int, default=20)
    parser.add_argument(
        "--somente-fixadas",
        action="store_true",
        help="imprime as tags fixadas no values, sem consultar o registry",
    )
    args = parser.parse_args()

    with open(args.values, encoding="utf-8") as arquivo:
        conteudo = arquivo.read()

    if args.somente_fixadas:
        # Serve para comparar dois values pelas tags que este ciclo governa, e não
        # pelo hash do arquivo: uma edição alheia no mesmo arquivo mudaria o hash sem
        # mudar um pin sequer. Chave ilegível vira texto no lugar do valor, para que a
        # comparação acuse diferença em vez de fingir igualdade.
        for imagem, (_, chave) in sorted(IMAGENS.items()):
            try:
                print(f"{imagem}\t{ler(conteudo, chave)}")
            except (ChaveNaoEncontrada, yaml_error) as erro:
                print(f"{imagem}\t<ilegível: {erro}>")
        return 0

    resultado = comparar(conteudo, args.timeout)

    print(json.dumps(resultado, ensure_ascii=False, indent=2))

    # Erro de consulta não deve promover nada, mesmo que outra imagem esteja pronta:
    # um bump parcial por falha de rede seria pior que nenhum.
    if resultado["erros"]:
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
