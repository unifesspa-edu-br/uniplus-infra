{{/*
Helpers comuns do chart apps/keycloak-replica/.
Usar `keycloak-replica.fullname` em todos os recursos para garantir
consistência entre Deployment, Service, ExternalSecret, IngressRoute, etc.
*/}}

{{/*
Nome base. Default: Release.Name (ApplicationSet gera `keycloak-replica-<cluster>`).
Override via `nameOverride`/`fullnameOverride` (não setados por default).
*/}}
{{- define "keycloak-replica.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "keycloak-replica.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Labels padrão Uni+ — compostos de Helm builtin + commonLabels do values.
Aplicar como `nindent 4` em metadata.labels.
*/}}
{{- define "keycloak-replica.labels" -}}
app.kubernetes.io/name: {{ include "keycloak-replica.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels — subset estável usado em selectors (Deployment.spec.selector,
Service.spec.selector, NetworkPolicy.spec.podSelector). NÃO incluir version/chart
aqui — selectors são imutáveis e mudar version quebra rolling update.
*/}}
{{- define "keycloak-replica.selectorLabels" -}}
app.kubernetes.io/name: {{ include "keycloak-replica.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Nome da ServiceAccount.
*/}}
{{- define "keycloak-replica.serviceAccountName" -}}
{{- if .Values.keycloak.serviceAccount.create }}
{{- default (include "keycloak-replica.fullname" .) .Values.keycloak.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.keycloak.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Nome do Secret K8s sintetizado a partir do ExternalSecret de DB credentials.
Mesmo nome serve para os outros (admin, client) com sufixo distinto.
*/}}
{{- define "keycloak-replica.dbSecretName" -}}
{{- printf "%s-db" (include "keycloak-replica.fullname" .) }}
{{- end }}

{{- define "keycloak-replica.adminSecretName" -}}
{{- printf "%s-bootstrap-admin" (include "keycloak-replica.fullname" .) }}
{{- end }}

{{- define "keycloak-replica.realmConfigMapName" -}}
{{- printf "%s-realm-uniplus" (include "keycloak-replica.fullname" .) }}
{{- end }}
