{{/*
Nome curto do release. AKHQ não tem peculiaridades de naming; segue
pattern padrão Helm (release.Chart) com truncate p/ DNS-1123.
*/}}
{{- define "kafkaUi.fullname" -}}
{{- if .Values.kafkaUi.fullnameOverride -}}
{{- .Values.kafkaUi.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.kafkaUi.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels (subset estável dos commonLabels — match.io.k.s/name e
match.io.k.s/instance só; version e managed-by mudam entre releases e
quebrariam selectors se incluídos).
*/}}
{{- define "kafkaUi.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.kafkaUi.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Labels padrão Uni+ + chart info, aplicados a TODOS os recursos do chart.
*/}}
{{- define "kafkaUi.labels" -}}
{{ include "kafkaUi.selectorLabels" . }}
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
{{- define "kafkaUi.serviceAccountName" -}}
{{- if .Values.kafkaUi.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "kafkaUi.fullname" .)) .Values.kafkaUi.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.kafkaUi.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Nome do Secret K8s sintetizado pelo ESO `kafkaCredentials` — convenção
<fullname>-kafka-credentials (usuário e senha por secretKeyRef; CA por volume).
*/}}
{{- define "kafkaUi.kafkaCredentialsSecretName" -}}
{{ include "kafkaUi.fullname" . }}-kafka-credentials
{{- end -}}

{{/*
Nome do Secret K8s sintetizado pelo ESO `oidcClient`.
*/}}
{{- define "kafkaUi.oidcClientSecretName" -}}
{{ include "kafkaUi.fullname" . }}-oidc-client
{{- end -}}

{{/*
Nome do Secret K8s sintetizado pelo ESO `jwt` — JWT signing secret do
Micronaut security do AKHQ.
*/}}
{{- define "kafkaUi.jwtSecretName" -}}
{{ include "kafkaUi.fullname" . }}-jwt
{{- end -}}

{{/*
Nome do ConfigMap com application.yml renderizado.
*/}}
{{- define "kafkaUi.configMapName" -}}
{{ include "kafkaUi.fullname" . }}-config
{{- end -}}

{{/*
Padrão de nome dos tópicos que o papel de leitura de conteúdo pode abrir: todos,
menos os de topicosSemLeituraNaInterface. O AKHQ só aceita padrões positivos
(regex Java, o recurso precisa casar com ao menos um); a exclusão é um lookahead
negativo ancorado no nome inteiro, com cada nome escapado como literal.
*/}}
{{- define "kafkaUi.padraoDeTopicosLegiveis" -}}
{{- $excluidos := list -}}
{{- range .Values.kafkaUi.topicosSemLeituraNaInterface -}}
{{- $excluidos = append $excluidos (regexQuoteMeta .) -}}
{{- end -}}
{{- if $excluidos -}}
^(?!(?:{{ join "|" $excluidos }})$).*$
{{- else -}}
.*
{{- end -}}
{{- end -}}
