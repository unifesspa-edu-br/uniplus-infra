{{/*
  Helpers comuns do chart vault-transit-bootstrap.
*/}}

{{- define "vault-transit-bootstrap.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vault-transit-bootstrap.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "vault-transit-bootstrap.labels" -}}
app.kubernetes.io/name: {{ include "vault-transit-bootstrap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: vault-transit-bootstrap
app.kubernetes.io/part-of: uniplus
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- define "vault-transit-bootstrap.selectorLabels" -}}
app.kubernetes.io/name: {{ include "vault-transit-bootstrap.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
  Nome da Secret K8s materializada pelo ExternalSecret. Constante para que
  Job e ExternalSecret referenciem o mesmo nome.
*/}}
{{- define "vault-transit-bootstrap.tokenSecretName" -}}
{{ include "vault-transit-bootstrap.fullname" . }}-token
{{- end -}}

{{/*
  Annotations padrão de hook Helm — todos os recursos exceto o Job rodam
  cedo (weight 0) para garantir SA/Secret/CM/NP presentes antes do Job
  (weight 10). hook-delete-policy preserva em falha para inspeção.
*/}}
{{- define "vault-transit-bootstrap.hookAnnotations" -}}
"helm.sh/hook": post-install,post-upgrade,post-rollback
"helm.sh/hook-weight": "0"
"helm.sh/hook-delete-policy": before-hook-creation
{{- end -}}
