{{/* Helpers do chart kes. O nome é fixo: um KES por cluster. */}}

{{- define "kes.name" -}}kes{{- end -}}

{{- define "kes.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kes.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "kes.labels" -}}
{{ include "kes.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: kms
app.kubernetes.io/part-of: uniplus
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- define "kes.tlsSecretName" -}}kes-tls{{- end -}}
{{- define "kes.identitiesSecretName" -}}kes-identities{{- end -}}
