{{/*
  Helpers do chart apps/clamav-espelho.
*/}}

{{- define "clamavEspelho.name" -}}
clamav-espelho
{{- end -}}

{{- define "clamavEspelho.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "clamavEspelho.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clamavEspelho.serviceAccountName" -}}
{{- if .Values.clamavEspelho.serviceAccount.create -}}
{{- default (include "clamavEspelho.fullname" .) .Values.clamavEspelho.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.clamavEspelho.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "clamavEspelho.labels" -}}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
app.kubernetes.io/name: {{ include "clamavEspelho.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "clamavEspelho.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clamavEspelho.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
