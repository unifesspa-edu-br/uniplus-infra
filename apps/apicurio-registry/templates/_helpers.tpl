{{/*
Nome curto do release. Apicurio não tem peculiaridades de naming;
segue pattern padrão Helm (release.Chart) com truncate p/ DNS-1123.
*/}}
{{- define "apicurioRegistry.fullname" -}}
{{- if .Values.apicurioRegistry.fullnameOverride -}}
{{- .Values.apicurioRegistry.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.apicurioRegistry.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels (subset estável dos commonLabels — match.io.k.s/name e
match.io.k.s/instance só; version e managed-by mudam entre releases e
quebrariam selectors se incluídos).
*/}}
{{- define "apicurioRegistry.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.apicurioRegistry.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Labels padrão Uni+ + chart info, aplicados a TODOS os recursos do chart.
*/}}
{{- define "apicurioRegistry.labels" -}}
{{ include "apicurioRegistry.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{/*
ServiceAccount name — usa Values.serviceAccount.name se setado, senão
fullname com sufixo "-sa".
*/}}
{{- define "apicurioRegistry.serviceAccountName" -}}
{{- if .Values.apicurioRegistry.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "apicurioRegistry.fullname" .)) .Values.apicurioRegistry.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.apicurioRegistry.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Nome do Secret K8s sintetizado pelo ESO `dbCreds` — JDBC password do role
`apicurio` no Postgres standalone.
*/}}
{{- define "apicurioRegistry.dbCredsSecretName" -}}
{{ include "apicurioRegistry.fullname" . }}-db
{{- end -}}

{{/*
Nome do Secret K8s sintetizado pelo ESO `oidcClient` — client_secret do
client confidential `apicurio-registry` no realm uniplus.
*/}}
{{- define "apicurioRegistry.oidcClientSecretName" -}}
{{ include "apicurioRegistry.fullname" . }}-oidc-client
{{- end -}}

{{/*
JDBC URL completa para o Postgres standalone. Storage host/port/database
vêm de values; postgresql é o único SQL kind suportado em produção
(H2 fica fora — só para dev local).
*/}}
{{- define "apicurioRegistry.jdbcUrl" -}}
jdbc:postgresql://{{ .Values.apicurioRegistry.storage.host }}:{{ .Values.apicurioRegistry.storage.port }}/{{ .Values.apicurioRegistry.storage.database }}
{{- end -}}
