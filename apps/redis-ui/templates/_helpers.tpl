{{/*
Nome curto do release. RedisInsight não tem peculiaridades de naming;
pattern padrão Helm (release.Chart) com truncate p/ DNS-1123.
*/}}
{{- define "redisUi.fullname" -}}
{{- if .Values.redisUi.fullnameOverride -}}
{{- .Values.redisUi.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.redisUi.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels (subset estável).
*/}}
{{- define "redisUi.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.redisUi.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Labels padrão Uni+ + chart info.
*/}}
{{- define "redisUi.labels" -}}
{{ include "redisUi.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "redisUi.serviceAccountName" -}}
{{- if .Values.redisUi.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "redisUi.fullname" .)) .Values.redisUi.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.redisUi.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Nomes dos Secrets sintetizados pelo ESO.
*/}}
{{- define "redisUi.redisDefaultSecretName" -}}
{{ include "redisUi.fullname" . }}-redis
{{- end -}}

{{- define "redisUi.basicAuthSecretName" -}}
{{ include "redisUi.fullname" . }}-basic-auth
{{- end -}}

{{- define "redisUi.basicAuthMiddlewareName" -}}
{{ include "redisUi.fullname" . }}-basic-auth
{{- end -}}
