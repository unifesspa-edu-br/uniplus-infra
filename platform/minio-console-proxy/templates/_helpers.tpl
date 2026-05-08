{{/*
Nome curto do release. Sem peculiaridades de naming; pattern padrão Helm
(release.Chart) com truncate p/ DNS-1123.
*/}}
{{- define "minioConsoleProxy.fullname" -}}
{{- if .Values.minioConsoleProxy.fullnameOverride -}}
{{- .Values.minioConsoleProxy.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.minioConsoleProxy.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels (subset estável dos commonLabels — match.io.k.s/name e
match.io.k.s/instance só; version e managed-by mudariam entre releases e
quebrariam selectors se incluídos).
*/}}
{{- define "minioConsoleProxy.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.minioConsoleProxy.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Labels padrão Uni+ + chart info, aplicados a TODOS os recursos do chart.
*/}}
{{- define "minioConsoleProxy.labels" -}}
{{ include "minioConsoleProxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}
