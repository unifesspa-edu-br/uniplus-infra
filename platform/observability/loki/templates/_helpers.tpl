{{/*
Helpers do wrapper Loki Uni+. Os helpers do chart upstream (loki.fullname,
loki.labels, etc.) ficam disponíveis via subchart e devem ser preferidos para
recursos do próprio Loki. Estes helpers cobrem APENAS recursos do wrapper
(ExternalSecret, NetworkPolicy) onde precisamos de nomes/labels consistentes
sem depender da resolução interna do subchart (`include "loki.x"` falha em
templates do wrapper porque o scope é do release pai).
*/}}

{{/*
Nome curto do wrapper. Usado em ExternalSecret + NetworkPolicy.
Reusa lógica padrão do Helm fullname (release-chart) com truncate em 63 chars
(limite RFC 1123 para nomes de recursos K8s).
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
Nome do Secret K8s sintetizado pelo ESO com credenciais MinIO.
Convenção: <fullname>-s3-creds (alinhado com pattern de outros wrappers Uni+).
*/}}
{{- define "uniplus-loki.s3SecretName" -}}
{{ include "uniplus-loki.fullname" . }}-s3-creds
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
Selector labels do StatefulSet do Loki SingleBinary. Bate com os labels
emitidos pelo subchart upstream em modo SingleBinary, usados pela
NetworkPolicy ingress para identificar pods do Loki como destino.
*/}}
{{- define "uniplus-loki.selectorLabels" -}}
app.kubernetes.io/name: loki
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: single-binary
{{- end -}}
