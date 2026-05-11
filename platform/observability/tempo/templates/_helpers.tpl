{{/*
Helpers do wrapper Tempo Uni+. Mesmo pattern do wrapper Loki: helpers cobrem
APENAS recursos próprios do wrapper (ExternalSecret, NetworkPolicy). Recursos
do Tempo upstream usam os helpers internos do subchart.
*/}}

{{- define "uniplus-tempo.fullname" -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Nome FIXO do Secret K8s sintetizado pelo ESO com credenciais MinIO.
Sem release prefix — independente do AppSet/cluster, o pod consome
sempre `tempo-s3-creds`.

Por que NÃO incluir release name (mesma análise do wrapper Loki, ADR-011):
o `tempo.extraEnvFrom` é consumido pelo subchart upstream que aceita apenas
valor literal — não suporta templating do nome no momento do render do
StatefulSet. Override possível via uniplusExternalSecrets.s3SecretName quando
precisar de 2+ releases Tempo no mesmo namespace.
*/}}
{{- define "uniplus-tempo.s3SecretName" -}}
{{- default (printf "%s-s3-creds" .Chart.Name) .Values.tempoWrapper.externalSecrets.s3SecretName -}}
{{- end -}}

{{- define "uniplus-tempo.labels" -}}
app.kubernetes.io/name: tempo
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: uniplus
app.kubernetes.io/component: tracing
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/*
Selector labels do StatefulSet do Tempo (single-binary). Bate com os labels
emitidos pelo subchart upstream `app.kubernetes.io/name: tempo` no mesmo
release. Usado pela NetworkPolicy.
*/}}
{{- define "uniplus-tempo.selectorLabels" -}}
app.kubernetes.io/name: tempo
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}
