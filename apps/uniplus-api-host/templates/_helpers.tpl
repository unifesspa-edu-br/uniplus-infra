{{/* Fullname com truncate DNS-1123. */}}
{{- define "uniplusApiHost.fullname" -}}
{{- if .Values.uniplusApiHost.fullnameOverride -}}
{{- .Values.uniplusApiHost.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.uniplusApiHost.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uniplusApiHost.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.uniplusApiHost.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uniplusApiHost.labels" -}}
{{ include "uniplusApiHost.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "uniplusApiHost.serviceAccountName" -}}
{{- if .Values.uniplusApiHost.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "uniplusApiHost.fullname" .)) .Values.uniplusApiHost.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.uniplusApiHost.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets sintetizados pelo ESO. */}}
{{- define "uniplusApiHost.postgresSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-postgres
{{- end -}}

{{- define "uniplusApiHost.redisSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-redis
{{- end -}}

{{- define "uniplusApiHost.kafkaSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-kafka
{{- end -}}

{{- define "uniplusApiHost.minioSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-minio
{{- end -}}

{{- define "uniplusApiHost.oidcSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-oidc-client
{{- end -}}
