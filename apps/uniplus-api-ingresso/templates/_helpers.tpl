{{/* Fullname com truncate DNS-1123. */}}
{{- define "uniplusApiIngresso.fullname" -}}
{{- if .Values.uniplusApiIngresso.fullnameOverride -}}
{{- .Values.uniplusApiIngresso.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.uniplusApiIngresso.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uniplusApiIngresso.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.uniplusApiIngresso.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uniplusApiIngresso.labels" -}}
{{ include "uniplusApiIngresso.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "uniplusApiIngresso.serviceAccountName" -}}
{{- if .Values.uniplusApiIngresso.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "uniplusApiIngresso.fullname" .)) .Values.uniplusApiIngresso.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.uniplusApiIngresso.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets sintetizados pelo ESO. */}}
{{- define "uniplusApiIngresso.postgresSecretName" -}}
{{ include "uniplusApiIngresso.fullname" . }}-postgres
{{- end -}}

{{- define "uniplusApiIngresso.redisSecretName" -}}
{{ include "uniplusApiIngresso.fullname" . }}-redis
{{- end -}}

{{- define "uniplusApiIngresso.kafkaSecretName" -}}
{{ include "uniplusApiIngresso.fullname" . }}-kafka
{{- end -}}

{{- define "uniplusApiIngresso.minioSecretName" -}}
{{ include "uniplusApiIngresso.fullname" . }}-minio
{{- end -}}

{{- define "uniplusApiIngresso.oidcSecretName" -}}
{{ include "uniplusApiIngresso.fullname" . }}-oidc-client
{{- end -}}
