{{/*
  Helpers do chart apps/clamav-scanner.
*/}}

{{- define "clamavScanner.name" -}}
clamav-scanner
{{- end -}}

{{- define "clamavScanner.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "clamavScanner.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "clamavScanner.serviceAccountName" -}}
{{- if .Values.clamavScanner.serviceAccount.create -}}
{{- default (include "clamavScanner.fullname" .) .Values.clamavScanner.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.clamavScanner.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "clamavScanner.labels" -}}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
app.kubernetes.io/name: {{ include "clamavScanner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{- define "clamavScanner.selectorLabels" -}}
app.kubernetes.io/name: {{ include "clamavScanner.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
