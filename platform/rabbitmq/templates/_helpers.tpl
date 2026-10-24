{{/* Helpers do chart rabbitmq. O nome é fixo: o Service é rabbitmq.<ns>. */}}

{{- define "rabbitmq.name" -}}rabbitmq{{- end -}}

{{- define "rabbitmq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "rabbitmq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "rabbitmq.labels" -}}
{{ include "rabbitmq.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: broker
app.kubernetes.io/part-of: uniplus
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- define "rabbitmq.credentialsSecretName" -}}rabbitmq-credentials{{- end -}}
