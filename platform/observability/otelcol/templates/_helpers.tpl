{{/*
Helpers do wrapper OTel Collector Uni+. Apenas para a NetworkPolicy
própria (chart upstream não emite NP útil para nosso modelo de
ingress/egress).
*/}}

{{- define "uniplus-otel.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uniplus-otel.labels" -}}
app.kubernetes.io/name: opentelemetry-collector
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: uniplus
app.kubernetes.io/component: collector
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Selector labels do DaemonSet do OTel Collector. Bate com os labels que
o subchart upstream emite para o pod (`app.kubernetes.io/name:
opentelemetry-collector` + instance).
*/}}
{{- define "uniplus-otel.selectorLabels" -}}
app.kubernetes.io/name: opentelemetry-collector
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
