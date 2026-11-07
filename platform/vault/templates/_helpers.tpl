{{/*
Nome do Service ativo criado pelo subchart hashicorp/vault. Reproduz o
`vault.fullname` do subchart: fullnameOverride, ou o nome do release quando ele
já contém o nome do chart, ou `<release>-<nome>`. O subchart não tem alias, então
seus values ficam em `.Values.vault`.
*/}}
{{- define "vault-wrapper.serviceName" -}}
{{- $sub := .Values.vault | default dict -}}
{{- if $sub.fullnameOverride -}}
{{- $sub.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "vault" $sub.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}
