{{/* Fullname com truncate DNS-1123. */}}
{{- define "uniplusApiPortal.fullname" -}}
{{- if .Values.uniplusApiPortal.fullnameOverride -}}
{{- .Values.uniplusApiPortal.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.uniplusApiPortal.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uniplusApiPortal.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.uniplusApiPortal.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uniplusApiPortal.labels" -}}
{{ include "uniplusApiPortal.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "uniplusApiPortal.serviceAccountName" -}}
{{- if .Values.uniplusApiPortal.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "uniplusApiPortal.fullname" .)) .Values.uniplusApiPortal.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.uniplusApiPortal.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets sintetizados pelo ESO. */}}
{{- define "uniplusApiPortal.postgresSecretName" -}}
{{ include "uniplusApiPortal.fullname" . }}-postgres
{{- end -}}

{{- define "uniplusApiPortal.redisSecretName" -}}
{{ include "uniplusApiPortal.fullname" . }}-redis
{{- end -}}

{{- define "uniplusApiPortal.kafkaSecretName" -}}
{{ include "uniplusApiPortal.fullname" . }}-kafka
{{- end -}}

{{- define "uniplusApiPortal.minioSecretName" -}}
{{ include "uniplusApiPortal.fullname" . }}-minio
{{- end -}}

{{- define "uniplusApiPortal.oidcSecretName" -}}
{{ include "uniplusApiPortal.fullname" . }}-oidc-client
{{- end -}}
