{{/*
Helpers dos recursos do wrapper (ExternalSecret, NetworkPolicy). Os do
subchart não são acessíveis daqui porque o escopo é o da release pai.
*/}}

{{/*
Nome dos recursos do wrapper: release-chart, truncado em 63 caracteres.
*/}}
{{- define "uniplus-loki.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Nome do Secret com as credenciais do MinIO. É fixo (sem o nome da release)
porque `singleBinary.extraEnvFrom` do subchart não aceita template: o
ambiente repete o mesmo nome ali. Para duas releases no mesmo namespace,
defina lokiWrapper.externalSecrets.s3SecretName.
*/}}
{{- define "uniplus-loki.s3SecretName" -}}
{{- default (printf "%s-s3-creds" .Chart.Name) .Values.lokiWrapper.externalSecrets.s3SecretName -}}
{{- end -}}

{{/*
Labels padrão Uni+ aplicados a recursos do wrapper.
*/}}
{{- define "uniplus-loki.labels" -}}
app.kubernetes.io/name: loki
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: uniplus
app.kubernetes.io/component: logging
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Labels de seleção dos pods do SingleBinary, iguais aos do subchart.
*/}}
{{- define "uniplus-loki.selectorLabels" -}}
app.kubernetes.io/name: loki
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: single-binary
{{- end -}}
