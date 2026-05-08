{{/* Fullname com truncate DNS-1123. */}}
{{- define "uniplusApiSelecao.fullname" -}}
{{- if .Values.uniplusApiSelecao.fullnameOverride -}}
{{- .Values.uniplusApiSelecao.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.uniplusApiSelecao.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uniplusApiSelecao.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.uniplusApiSelecao.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uniplusApiSelecao.labels" -}}
{{ include "uniplusApiSelecao.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "uniplusApiSelecao.serviceAccountName" -}}
{{- if .Values.uniplusApiSelecao.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "uniplusApiSelecao.fullname" .)) .Values.uniplusApiSelecao.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.uniplusApiSelecao.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets sintetizados pelo ESO. */}}
{{- define "uniplusApiSelecao.postgresSecretName" -}}
{{ include "uniplusApiSelecao.fullname" . }}-postgres
{{- end -}}

{{- define "uniplusApiSelecao.redisSecretName" -}}
{{ include "uniplusApiSelecao.fullname" . }}-redis
{{- end -}}

{{- define "uniplusApiSelecao.kafkaSecretName" -}}
{{ include "uniplusApiSelecao.fullname" . }}-kafka
{{- end -}}

{{- define "uniplusApiSelecao.minioSecretName" -}}
{{ include "uniplusApiSelecao.fullname" . }}-minio
{{- end -}}

{{- define "uniplusApiSelecao.oidcSecretName" -}}
{{ include "uniplusApiSelecao.fullname" . }}-oidc-client
{{- end -}}
