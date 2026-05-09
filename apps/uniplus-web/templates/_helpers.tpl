{{/*
  Fullname-base do release. Cada app web (portal/seleção/ingresso) é um
  Deployment separado com sufixo do app: `<release>-<chart>-<app>`.

  Truncate aplicado em camadas para garantir DNS-1123 (≤63 chars) tanto no
  fullname-base quanto no nome final concatenado com o app.
*/}}
{{- define "uniplusWeb.fullname" -}}
{{- if .Values.uniplusWeb.fullnameOverride -}}
{{- .Values.uniplusWeb.fullnameOverride | trunc 53 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.uniplusWeb.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 53 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
  Per-app fullname: `<fullname>-<app>`.

  Recebe um dict com `ctx` (root context) e `app` (nome do app — portal/
  selecao/ingresso). Trunca a 63 chars para não exceder limite DNS-1123.
*/}}
{{- define "uniplusWeb.appFullname" -}}
{{- printf "%s-%s" (include "uniplusWeb.fullname" .ctx) .app | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Selector labels comuns a todo o chart, mais o sufixo `app.kubernetes.io/
  component-instance` que distingue os 3 deployments dentro do release.
*/}}
{{- define "uniplusWeb.selectorLabels" -}}
{{- $name := default .ctx.Chart.Name .ctx.Values.uniplusWeb.nameOverride -}}
app.kubernetes.io/name: {{ $name }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component-instance: {{ .app }}
{{- end -}}

{{- define "uniplusWeb.labels" -}}
{{ include "uniplusWeb.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .ctx.Chart.Name .ctx.Chart.Version | replace "+" "_" }}
{{- with .ctx.Values.uniplusWeb.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "uniplusWeb.serviceAccountName" -}}
{{- if .ctx.Values.uniplusWeb.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "uniplusWeb.appFullname" .)) .ctx.Values.uniplusWeb.serviceAccount.name -}}
{{- else -}}
{{- default "default" .ctx.Values.uniplusWeb.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
  Image fully-qualified: registry/repository/<image>:<tag>.
  Resolve tag com fallback `apps.<name>.tag` → `image.tag` → `Chart.AppVersion`.
*/}}
{{- define "uniplusWeb.image" -}}
{{- $img := .appCfg.image -}}
{{- $tag := .appCfg.tag | default .ctx.Values.uniplusWeb.image.tag | default .ctx.Chart.AppVersion -}}
{{- printf "%s/%s/%s:%s" .ctx.Values.uniplusWeb.image.registry .ctx.Values.uniplusWeb.image.repository $img $tag -}}
{{- end -}}

{{/*
  ConfigMap nome (runtime-config.json) per-app.
*/}}
{{- define "uniplusWeb.runtimeConfigMapName" -}}
{{ include "uniplusWeb.appFullname" . }}-runtime-config
{{- end -}}
