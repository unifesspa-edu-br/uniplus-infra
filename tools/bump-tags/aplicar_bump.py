#!/usr/bin/env python3
"""Aplica no values as tags novas e monta o corpo do PR.

A localização de cada pin vem do parser de YAML e a troca atinge só aquela linha
(ver `values_tags`): reserializar o documento apagaria os comentários que explicam
cada pin, e casar por texto trocaria de uma vez as quatro chaves que hoje
compartilham a mesma tag.

O corpo do PR traz as migrations do intervalo e marca as destrutivas — um bump de
tag sozinho não dá base para decidir se o merge pode ser rotineiro.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys

from values_tags import escrever, ler

# Operações que tornam o schema incompatível com a versão anterior da aplicação —
# que é o que importa aqui, porque durante o rollout quem ainda responde é ela.
# Renomear conta: para o código antigo, a coluna sumiu.
# Destrutiva aqui quer dizer uma coisa só: o objeto que o código anterior NOMEIA deixa
# de existir com aquele nome. Coluna, tabela, schema e sequência — removidos ou
# renomeados — quebram a escrita de quem ainda responde durante o rollout.
DESTRUTIVAS = (
    "DropColumn",
    "DropTable",
    "DropSchema",
    "DropSequence",
    "RenameColumn",
    "RenameTable",
    "RenameSequence",
)

# Remover restrição ou índice NÃO entra aqui, e a distinção é a mesma que já valia para
# `DropUniqueConstraint` e `DropCheckConstraint`: essas operações RELAXAM a regra em vez
# de apertá-la, e a versão anterior segue escrevendo dados que já eram aceitos. Chamá-las
# de destrutivas daria o alerta mais forte do texto a uma troca rotineira de índice — e
# alerta que exagera é alerta que se aprende a ignorar. Ficam na revisão, onde o impacto
# real (integridade, desempenho) é o que se confere.
#
# Também ficam de fora, sem aviso algum:
#
# - `RenameIndex`: nada no código de escrita nomeia índice; só o DDL o referencia.
# - `CreateTable`, `CreateSequence`, `EnsureSchema`, `InsertData`: acrescentam, e o
#   que a versão anterior não conhece ela não usa.

# Operações cujo efeito não é inferível só pelo nome. Ficam numa categoria própria em
# vez de inflar a de destrutivas: marcar como destrutivo o que talvez não seja faria o
# aviso aparecer em todo bump, e aviso que sempre aparece deixa de ser lido.
AVISO_ALTER_COLUMN = "altera coluna existente — conferir tipo, tamanho e nulidade"
AVISO_ALTER_SEQUENCE = (
    "altera sequência existente — conferir incremento e limites, que podem recusar o "
    "próximo valor"
)
AVISO_REINICIA_SEQUENCE = (
    "reinicia sequência — se o valor novo ficar abaixo do que já foi usado, o próximo "
    "insert colide com chave existente"
)

# As operações que o `MigrationBuilder` do EF Core expõe e que NÃO geram aviso, cada uma
# por um motivo. A lista fecha a classificação: o que não está aqui nem nas categorias
# acima cai no aviso de operação desconhecida, e é assim que uma operação nova de uma
# versão futura do EF chega a quem revisa em vez de passar em silêncio.
#
# Obtida por reflexão sobre `MigrationBuilder` (EF Core 10.0.9), não de memória — a
# lista escrita à mão já saiu incompleta uma vez.
SEM_RISCO_DECLARADO = frozenset({
    # Acrescentam: o que a versão anterior não conhece, ela não usa.
    "CreateTable", "CreateSequence", "EnsureSchema", "InsertData",
    # Relaxam a regra em vez de apertá-la.
    "DropUniqueConstraint", "DropCheckConstraint",
    # Não são nomeados pelo código de escrita.
    "RenameIndex",
    # Anotações de provider, sem efeito sobre a escrita.
    "AlterDatabase", "AlterTable",
    # Tratadas pelo conteúdo dos argumentos, não pelo nome (ver `avisos_da_migration`).
    "AddColumn", "CreateIndex",
})
AVISO_OPERACAO_DESCONHECIDA = (
    "operação {operacao}, que esta classificação não conhece — conferir o efeito sobre "
    "a versão anterior"
)
AVISO_SQL_BRUTO = "contém SQL bruto — o efeito não é inferível pela operação"
# Restrições novas recusam duas coisas ao mesmo tempo: a linha que já está no banco e
# violaria, e a escrita que a versão anterior continua fazendo durante o rollout — ela
# não conhece a regra e não tem como respeitá-la.
AVISOS_DE_RESTRICAO = {
    "AddForeignKey": "adiciona chave estrangeira — recusa referência órfã existente e escrita da versão anterior",
    "AddCheckConstraint": "adiciona restrição de verificação — recusa linha que já viola e escrita da versão anterior",
    "CreateCheckConstraint": "adiciona restrição de verificação — recusa linha que já viola e escrita da versão anterior",
    "AddUniqueConstraint": "adiciona restrição de unicidade — recusa duplicata existente e escrita da versão anterior",
    "AddPrimaryKey": "adiciona chave primária — recusa nulo e duplicata existentes",
}
# Remoção de linha de seed. Não some estrutura, então não é destrutiva no sentido do
# schema — mas é uma exclusão de dado, e o efeito depende de o registro removido ainda
# ser referenciado. Marcar SQL bruto porque PODE conter um DELETE e deixar passar a
# operação que É um DELETE seria incoerente.
AVISOS_DE_RELAXAMENTO = {
    "DropIndex": "remove índice — a escrita segue válida, mas consulta que dependia dele pode degradar",
    "DropForeignKey": "remove chave estrangeira — deixa de haver garantia de integridade referencial",
    "DropPrimaryKey": "remove chave primária — conferir se outra a substitui na mesma migration",
}
AVISO_ATUALIZACAO_DE_DADO = (
    "altera linhas — a versão anterior pode interpretar o valor novo de outro jeito"
)
AVISO_REMOCAO_DE_DADO = (
    "remove linhas — conferir se o dado apagado ainda é referenciado pela versão anterior"
)
AVISO_INDICE_UNICO = (
    "cria índice único — recusa duplicata existente e escrita da versão anterior"
)
AVISO_COLUNA_OBRIGATORIA = (
    "adiciona coluna obrigatória sem valor padrão — falha se a tabela já tem linhas, "
    "e durante o rollout a versão anterior insere sem ela"
)


def aplicar(values: str, mudancas: list[dict]) -> tuple[str, list[str]]:
    """Troca cada tag pela nova, uma chave por vez."""
    aplicadas = []
    for mudanca in mudancas:
        chave, de, para = mudanca["chave"], mudanca["de"], mudanca["para"]
        atual = ler(values, chave)
        if atual != de:
            # O values mudou entre a verificação e a aplicação. Promover assim mesmo
            # sobrescreveria a decisão de outra pessoa.
            raise ValueError(
                f"{chave} está em {atual}, e não em {de} como a verificação apurou; "
                "o values mudou no meio do caminho"
            )
        values = escrever(values, chave, para)
        aplicadas.append(f"{chave}: {de} → {para}")
    return values, aplicadas


class IntervaloIndeterminado(RuntimeError):
    """Não foi possível apurar as migrations do intervalo."""


def _fim_do_literal(texto: str, i: int) -> int:
    """Índice logo após o literal que começa em `i`, ou `i` se ali não começa um."""
    verbatim = False
    if texto[i] in "@$":
        j = i
        while j < len(texto) and texto[j] in "@$":
            verbatim = verbatim or texto[j] == "@"
            j += 1
        if j >= len(texto) or texto[j] != '"':
            return i
        i = j
    if texto[i] == "'":
        i += 1
        while i < len(texto):
            if texto[i] == "\\":
                i += 2
                continue
            if texto[i] == "'":
                return i + 1
            i += 1
        return i
    if texto[i] != '"':
        return i

    # Raw string literal (C# 11+): abre com três ou mais aspas e fecha com a MESMA
    # quantidade; entre elas, aspas soltas são conteúdo. Sem isto, `"""` é lido como
    # uma string vazia seguida de outra string, e o texto seguinte passa a ser
    # interpretado ao contrário — o que engoliria uma chamada destrutiva posterior
    # como se fosse argumento do `Sql`. As migrations do projeto usam esta forma.
    if texto.startswith('"""', i):
        abertura = 0
        while texto[i + abertura : i + abertura + 1] == '"':
            abertura += 1
        j = i + abertura
        while j < len(texto):
            if texto[j] != '"':
                j += 1
                continue
            fechamento = 0
            while texto[j + fechamento : j + fechamento + 1] == '"':
                fechamento += 1
            if fechamento >= abertura:
                return j + fechamento
            j += fechamento
        return len(texto)

    i += 1
    while i < len(texto):
        if verbatim:
            if texto[i] == '"':
                # Em literal verbatim a aspa é escapada duplicando-a. A aspa dupla
                # CONTINUA o literal; só a solitária o encerra. Tratar `""` como fim
                # partiria um `@"SELECT ""Coluna"" FROM t"` ao meio, e o resto do SQL
                # seria lido como código.
                if texto[i + 1 : i + 2] == '"':
                    i += 2
                    continue
                return i + 1
        elif texto[i] == "\\":
            i += 2
            continue
        elif texto[i] == '"':
            return i + 1
        i += 1
    return i


def _fim_do_comentario(texto: str, i: int) -> int:
    """Índice logo após o comentário que começa em `i`, ou `i` se ali não começa um."""
    if texto.startswith("//", i):
        quebra = texto.find("\n", i)
        return len(texto) if quebra == -1 else quebra + 1
    if texto.startswith("/*", i):
        fim = texto.find("*/", i + 2)
        return len(texto) if fim == -1 else fim + 2
    return i


def _avancar(texto: str, i: int, abre: str, fecha: str) -> int:
    """Índice logo após o fechamento que corresponde ao `abre` na posição `i`."""
    profundidade = 0
    while i < len(texto):
        for pular in (_fim_do_literal, _fim_do_comentario):
            depois = pular(texto, i)
            if depois != i:
                i = depois
                break
        else:
            if texto[i] == abre:
                profundidade += 1
            elif texto[i] == fecha:
                profundidade -= 1
                if profundidade == 0:
                    return i + 1
            i += 1
    return i


def chamadas_do_migration_builder(trecho: str) -> list[tuple[str, str]]:
    """Cada chamada a `migrationBuilder.X(...)`, como (operação, argumentos).

    A varredura respeita literais de string, e é por isso que ela existe em vez de uma
    busca por texto: um `defaultValueSql: "coalesce(valor, 0)"` fecharia a chamada cedo
    demais numa contagem ingênua de parênteses, e o resto dos argumentos passaria a ser
    lido como outra chamada. Genéricos (`AddColumn<string>`) também são pulados como
    par balanceado, porque podem aninhar.
    """
    chamadas = []
    marcador = "migrationBuilder."
    i = 0
    while i < len(trecho):
        # Literais e comentários são pulados ANTES de procurar o marcador, e não
        # depois. Achar o candidato com uma busca de texto e só então perguntar onde
        # ele estava reconheceria `// migrationBuilder.DropTable(...)` como chamada
        # real — o mesmo defeito da classificação por substring, entrando pela outra
        # ponta.
        for pular in (_fim_do_literal, _fim_do_comentario):
            depois = pular(trecho, i)
            if depois != i:
                i = depois
                break
        else:
            if not trecho.startswith(marcador, i):
                i += 1
                continue
            j = i + len(marcador)
            inicio_do_nome = j
            while j < len(trecho) and (trecho[j].isalnum() or trecho[j] == "_"):
                j += 1
            operacao = trecho[inicio_do_nome:j]
            if j < len(trecho) and trecho[j] == "<":
                j = _avancar(trecho, j, "<", ">")
            if operacao and j < len(trecho) and trecho[j] == "(":
                fim = _avancar(trecho, j, "(", ")")
                chamadas.append((operacao, trecho[j + 1 : fim - 1]))
                i = fim
            else:
                i = j
    return chamadas


def argumentos_nomeados(argumentos: str) -> dict[str, str]:
    """Os argumentos `nome: valor` da chamada, separados no nível de fora."""
    partes, atual, i, inicio = [], [], 0, 0
    profundidade = 0
    while i < len(argumentos):
        depois = _fim_do_literal(argumentos, i)
        if depois != i:
            i = depois
            continue
        caractere = argumentos[i]
        if caractere in "([{<":
            profundidade += 1
        elif caractere in ")]}>":
            profundidade -= 1
        elif caractere == "," and profundidade == 0:
            partes.append(argumentos[inicio:i])
            inicio = i + 1
        i += 1
    partes.append(argumentos[inicio:])

    nomeados = {}
    for parte in partes:
        limpa = parte.strip()
        separador = limpa.find(":")
        if separador == -1:
            continue
        nome = limpa[:separador].strip()
        if nome.isidentifier():
            nomeados[nome] = limpa[separador + 1 :].strip()
    return nomeados


def avisos_da_migration(up: str) -> list[str]:
    """O que, no corpo do `Up`, quem revisa o bump precisa conferir antes de promover."""
    avisos = set()
    for operacao, argumentos in chamadas_do_migration_builder(up):
        if operacao == "Sql":
            avisos.add(AVISO_SQL_BRUTO)
        elif operacao == "DeleteData":
            avisos.add(AVISO_REMOCAO_DE_DADO)
        elif operacao == "UpdateData":
            avisos.add(AVISO_ATUALIZACAO_DE_DADO)
        elif operacao in AVISOS_DE_RELAXAMENTO:
            avisos.add(AVISOS_DE_RELAXAMENTO[operacao])
        elif operacao in AVISOS_DE_RESTRICAO:
            avisos.add(AVISOS_DE_RESTRICAO[operacao])
        elif operacao == "CreateIndex":
            # Índice comum é inofensivo para quem escreve; único é uma restrição, e
            # entra pelo mesmo motivo das demais.
            if argumentos_nomeados(argumentos).get("unique", "").rstrip(",") == "true":
                avisos.add(AVISO_INDICE_UNICO)
        elif operacao == "AlterColumn":
            avisos.add(AVISO_ALTER_COLUMN)
        elif operacao == "AlterSequence":
            avisos.add(AVISO_ALTER_SEQUENCE)
        elif operacao == "RestartSequence":
            avisos.add(AVISO_REINICIA_SEQUENCE)
        elif operacao not in DESTRUTIVAS and operacao not in SEM_RISCO_DECLARADO:
            avisos.add(AVISO_OPERACAO_DESCONHECIDA.format(operacao=operacao))
        elif operacao == "AddColumn":
            # Coluna nova é inofensiva, EXCETO obrigatória sem valor padrão, que falha
            # de duas maneiras: a própria migration é recusada se a tabela já tem
            # linhas, e durante o rollout o pod da versão anterior segue inserindo sem
            # a coluna. Homologação caiu pelo primeiro caminho em 25/08 — a tabela
            # parecia vazia pelo endpoint, mas guardava linhas com exclusão lógica. Com
            # `defaultValue` ou `defaultValueSql` o padrão fica na coluna e os dois
            # casos se resolvem.
            nomeados = argumentos_nomeados(argumentos)
            obrigatoria = nomeados.get("nullable", "").rstrip(",") == "false"
            # Pelo VALOR, e não pela presença da chave: `defaultValue: null` declara
            # explicitamente que não há padrão, e a coluna continua recusando as linhas
            # existentes e a escrita da versão anterior.
            sem_padrao = all(
                nomeados.get(chave, "null").rstrip(",").strip() == "null"
                for chave in ("defaultValue", "defaultValueSql")
            )
            if obrigatoria and sem_padrao:
                avisos.add(AVISO_COLUNA_OBRIGATORIA)
    return sorted(avisos)


def corpo_do_up(conteudo: str) -> str:
    """O corpo do método `Up`, e só ele.

    O arquivo é gerado pelo EF, e numa migration aditiva o `Down()` traz as
    operações inversas — `DropColumn` para uma coluna adicionada, `DropTable` para
    uma tabela criada. Classificar pelo arquivo inteiro marcaria como destrutiva
    justamente a migration mais comum e inofensiva, e o aviso de risco perderia o
    sentido por excesso.

    O recorte é entre as assinaturas dos dois métodos, que o EF sempre gera nessa
    ordem. Vale por ser código gerado, com forma estável — não serviria para código
    escrito à mão.
    """
    inicio = conteudo.find("void Up(")
    if inicio == -1:
        raise IntervaloIndeterminado("migration sem método Up reconhecível")
    fim = conteudo.find("void Down(", inicio)
    return conteudo[inicio:fim if fim != -1 else len(conteudo)]


def migrations_do_intervalo(repo: str, de: str, para: str) -> list[dict]:
    """Migrations adicionadas entre duas tags, com o aviso de destrutividade."""
    try:
        saida = subprocess.run(
            ["git", "-C", repo, "diff", "--name-only", f"{de}..{para}", "--", "*/Migrations/*.cs"],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as erro:
        # Devolver lista vazia diria "nenhuma migration", que é o oposto de "não sei".
        # Uma tag ausente no checkout esconderia migrations destrutivas justamente de
        # quem vai decidir o merge com base nesta informação.
        raise IntervaloIndeterminado(
            f"não foi possível comparar {de}..{para} no checkout da api: {erro}"
        ) from erro

    encontradas = []
    for caminho in saida.splitlines():
        # Definido pelo que uma migration É, e não por uma lista do que ela não pode
        # conter. O nome depois do timestamp é escolhido por quem cria, então qualquer
        # exclusão por texto — `Designer`, `ModelSnapshot` — acaba descartando uma
        # migration legítima, e as operações destrutivas dela somem do aviso sem que
        # nada indique a omissão.
        #
        # O que distingue: migration sempre começa com o carimbo de 14 dígitos e o
        # sublinhado que o EF gera; o snapshot do contexto e os arquivos `.Designer.cs`
        # não têm esse prefixo (o snapshot) ou têm aquele sufixo exato.
        nome = caminho.rsplit("/", 1)[-1]
        e_migration = (
            nome[:14].isdigit()
            and nome[14:15] == "_"
            and nome.endswith(".cs")
            and not nome.endswith(".Designer.cs")
        )
        if not caminho or not e_migration:
            continue
        try:
            conteudo = subprocess.run(
                ["git", "-C", repo, "show", f"{para}:{caminho}"],
                capture_output=True, text=True, check=True,
            ).stdout
        except subprocess.CalledProcessError as erro:
            raise IntervaloIndeterminado(f"não foi possível ler {caminho}: {erro}") from erro

        up = corpo_do_up(conteudo)
        # Pelas chamadas que o scanner extraiu, e não por busca de texto no corpo. Um
        # comentário ou nome de índice contendo "DropTable" marcaria a migration como
        # destrutiva sem que a operação existisse — dando o alerta mais forte do texto
        # a quem não o merece. É a mesma razão pela qual os avisos já saem daqui: uma
        # fonte só sobre o que a migration realmente chama.
        chamadas = {operacao for operacao, _ in chamadas_do_migration_builder(up)}
        operacoes = sorted(chamadas & set(DESTRUTIVAS))
        encontradas.append({
            "arquivo": caminho.rsplit("/", 1)[-1],
            "destrutiva": bool(operacoes),
            "operacoes": operacoes,
            "revisar": avisos_da_migration(up),
        })
    return encontradas


def corpo_do_pr(mudancas: list[dict], migrations: list[dict] | None, aplicadas: list[str]) -> str:
    linhas = [
        "Versões novas publicadas no GHCR. Este PR **não** foi mergeado automaticamente:",
        "promover para homologação continua sendo uma decisão humana.",
        "",
        "## Tags",
        "",
        "| Chave | De | Para |",
        "|---|---|---|",
    ]
    linhas += [f"| `{m['chave']}` | `{m['de']}` | `{m['para']}` |" for m in mudancas]

    destrutivas = [m for m in (migrations or []) if m["destrutiva"]]
    linhas += ["", "## Migrations no intervalo", ""]
    if migrations is None:
        linhas += [
            "> **Não foi possível apurar.** Conferir manualmente antes de promover — a ausência",
            "> desta lista não significa que o bump não altera schema.",
        ]
    elif not migrations:
        linhas.append("Nenhuma. O bump não altera schema.")
    else:
        if destrutivas:
            uma = len(destrutivas) == 1
            linhas += [
                f"> **{len(destrutivas)} de {len(migrations)} "
                f"{'é destrutiva' if uma else 'são destrutivas'}.** Uma migration que remove",
                "> estrutura não é compatível com a versão anterior da aplicação: enquanto o rollout",
                "> acontece, quem ainda responde é a versão antiga. Conferir antes de mergear.",
                "",
            ]
        for m in migrations:
            marcas = []
            if m["destrutiva"]:
                marcas.append(f"**destrutiva** ({', '.join(m['operacoes'])})")
            marcas.extend(m["revisar"])

            # Uma marca cabe na mesma linha; várias viram lista. Emendadas por
            # ponto e vírgula, quatro avisos formam um parágrafo que ninguém lê até o
            # fim — e o que se perde no fim é justamente o que motivou o aviso.
            if not marcas:
                linhas.append(f"- `{m['arquivo']}`")
            elif len(marcas) == 1:
                linhas.append(f"- `{m['arquivo']}` — {marcas[0]}")
            else:
                linhas.append(f"- `{m['arquivo']}`")
                linhas += [f"  - {marca}" for marca in marcas]

    linhas += [
        "",
        "## Verificação",
        "",
        "- Versões lidas do registry por consulta anônima — a API de packages do GitHub responde",
        "  403 por falta de escopo nas contas do projeto, e usá-la faria a checagem parecer vazia.",
        "- Todas as imagens existem: a versão só entra aqui porque foi encontrada publicada.",
        "",
        "<details><summary>Substituições aplicadas</summary>",
        "",
    ] + [f"- {a}" for a in aplicadas] + ["", "</details>"]
    return "\n".join(linhas)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--values", required=True)
    parser.add_argument("--comparacao", required=True, help="JSON produzido por verificar_versoes.py")
    parser.add_argument("--repo-api", help="checkout da uniplus-api, para listar as migrations")
    parser.add_argument("--saida-corpo", required=True)
    args = parser.parse_args()

    with open(args.comparacao, encoding="utf-8") as arquivo:
        comparacao = json.load(arquivo)
    mudancas = comparacao["desatualizadas"]
    if not mudancas:
        print("Nada a promover.")
        return 1

    with open(args.values, encoding="utf-8") as arquivo:
        values = arquivo.read()
    values, aplicadas = aplicar(values, mudancas)
    with open(args.values, "w", encoding="utf-8") as arquivo:
        arquivo.write(values)

    migrations: list[dict] | None = []
    api = next((m for m in mudancas if m["imagem"] == "uniplus-api-host"), None)
    if api and args.repo_api:
        try:
            migrations = migrations_do_intervalo(args.repo_api, api["de"], api["para"])
        except IntervaloIndeterminado as erro:
            print(f"aviso: {erro}", file=sys.stderr)
            migrations = None

    with open(args.saida_corpo, "w", encoding="utf-8") as arquivo:
        arquivo.write(corpo_do_pr(mudancas, migrations, aplicadas))

    print("\n".join(aplicadas))
    return 0


if __name__ == "__main__":
    sys.exit(main())
