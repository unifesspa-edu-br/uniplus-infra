#!/usr/bin/env python3
"""
Valida nomes de container em manifests K8s renderizados (Pod templates) contra
RFC 1123 label, complementando `kubeconform` (que valida estrutura/OpenAPI mas
não captura regras de naming impostas pela admission do API server).

O bug que motivou este script: charts wrapper que usam `alias: externalSecrets`
(Chart.yaml) acabam com Chart.Name camelCase. O template upstream usa
`{{ .Chart.Name }}` literalmente como nome do container. Resultado: container
`externalSecrets` no rendered output — K8s API rejeita por RFC 1123:
  "Invalid value: 'externalSecrets': a lowercase RFC 1123 label must consist
   of lower case alphanumeric characters or '-', and must start and end with
   an alphanumeric character"

helm lint, helm template, kubeconform e kubectl --dry-run=client NÃO pegam
isso. Só `kubectl --dry-run=server` (cluster real) pega — daí esta validação
estática focada.

Uso:
  python3 scripts/validate-rfc1123.py <manifests.yaml> [...]
  helm template chart/ | python3 scripts/validate-rfc1123.py -

Saída: zero issues → exit 0; qualquer issue → exit 1 com lista no stderr.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

RFC1123_LABEL = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")

# Kinds que carregam Pod template embedded.
WORKLOAD_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Pod", "Job"}


def pod_spec(doc: dict) -> dict | None:
    """Extrai o PodSpec embedded de um manifest workload."""
    kind = doc.get("kind")
    spec = doc.get("spec", {})
    if kind == "Pod":
        return spec
    if kind == "CronJob":
        return spec.get("jobTemplate", {}).get("spec", {}).get("template", {}).get("spec")
    if kind in WORKLOAD_KINDS:
        return spec.get("template", {}).get("spec")
    return None


def validate_doc(doc: dict, source: str) -> list[str]:
    """Devolve lista de issues encontradas no doc."""
    issues: list[str] = []
    if not isinstance(doc, dict):
        return issues
    kind = doc.get("kind")
    name = doc.get("metadata", {}).get("name", "<no-name>")

    ps = pod_spec(doc)
    if ps is None:
        return issues

    for container_field in ("containers", "initContainers"):
        for container in ps.get(container_field, []) or []:
            cname = container.get("name", "")
            if not RFC1123_LABEL.match(cname):
                issues.append(
                    f"{source}: {kind}/{name} {container_field}[].name=\"{cname}\" "
                    "fails RFC 1123 label "
                    "(lowercase alphanumeric + '-', start/end alphanumeric)"
                )
    return issues


def validate_stream(stream, source: str) -> list[str]:
    issues: list[str] = []
    try:
        docs = list(yaml.safe_load_all(stream))
    except yaml.YAMLError as exc:
        return [f"{source}: YAML parse error: {exc}"]
    for doc in docs:
        issues.extend(validate_doc(doc, source))
    return issues


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2

    all_issues: list[str] = []
    for arg in argv[1:]:
        if arg == "-":
            all_issues.extend(validate_stream(sys.stdin, "<stdin>"))
        else:
            path = Path(arg)
            if not path.is_file():
                print(f"error: {arg}: not a file", file=sys.stderr)
                return 2
            with path.open("r", encoding="utf-8") as fh:
                all_issues.extend(validate_stream(fh, str(path)))

    if all_issues:
        print(f"✗ RFC 1123 violations ({len(all_issues)}):", file=sys.stderr)
        for issue in all_issues:
            print(f"  {issue}", file=sys.stderr)
        return 1
    print("✓ all container names pass RFC 1123 label validation", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
