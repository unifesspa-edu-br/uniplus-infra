{{/* Fullname com truncate DNS-1123. */}}
{{- define "unifesspaGeoApi.fullname" -}}
{{- if .Values.unifesspaGeoApi.fullnameOverride -}}
{{- .Values.unifesspaGeoApi.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.unifesspaGeoApi.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "unifesspaGeoApi.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.unifesspaGeoApi.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "unifesspaGeoApi.labels" -}}
{{ include "unifesspaGeoApi.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "unifesspaGeoApi.serviceAccountName" -}}
{{- if .Values.unifesspaGeoApi.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "unifesspaGeoApi.fullname" .)) .Values.unifesspaGeoApi.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.unifesspaGeoApi.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets (sintetizados pelo ESO ou criados manualmente quando
     externalSecrets.enabled=false — ver README). */}}
{{- define "unifesspaGeoApi.postgresSecretName" -}}
{{ include "unifesspaGeoApi.fullname" . }}-postgres
{{- end -}}

{{- define "unifesspaGeoApi.redisSecretName" -}}
{{ include "unifesspaGeoApi.fullname" . }}-redis
{{- end -}}

{{- define "unifesspaGeoApi.encryptionSecretName" -}}
{{ include "unifesspaGeoApi.fullname" . }}-encryption
{{- end -}}
