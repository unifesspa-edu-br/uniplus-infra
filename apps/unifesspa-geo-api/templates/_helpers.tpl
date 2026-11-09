{{/* Fullname com truncate DNS-1123. */}}
{{- define "unifesspaGeoApi.fullname" -}}
{{- if .Values.unifesspaGeoApi.fullnameOverride -}}
{{- .Values.unifesspaGeoApi.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.unifesspaGeoApi.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "unifesspaGeoApi.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.unifesspaGeoApi.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "unifesspaGeoApi.labels" -}}
{{ include "unifesspaGeoApi.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "unifesspaGeoApi.serviceAccountName" -}}
{{- if .Values.unifesspaGeoApi.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "unifesspaGeoApi.fullname" .)) .Values.unifesspaGeoApi.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.unifesspaGeoApi.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets (sintetizados pelo ESO ou criados manualmente quando
     externalSecrets.enabled=false — ver README). */}}
{{- define "unifesspaGeoApi.postgresSecretName" -}}
{{ include "unifesspaGeoApi.fullname" . }}-postgres
{{- end -}}

{{- define "unifesspaGeoApi.redisSecretName" -}}
{{ include "unifesspaGeoApi.fullname" . }}-redis
{{- end -}}

{{- define "unifesspaGeoApi.encryptionSecretName" -}}
{{ include "unifesspaGeoApi.fullname" . }}-encryption
{{- end -}}

{{/*
  Referência da imagem. Com image.digest preenchido, a imagem é puxada pelo
  digest e a tag só identifica a versão: uma tag movida no registro não troca o
  que roda. O digest precisa ser sha256 completo.
*/}}
{{- define "unifesspaGeoApi.imagem" -}}
{{- $img := .Values.unifesspaGeoApi.image -}}
{{- $ref := printf "%s/%s:%s" $img.registry $img.repository $img.tag -}}
{{- $digest := $img.digest -}}
{{- if not (or (kindIs "invalid" $digest) (eq (toString $digest) "")) -}}
{{- if not (and (kindIs "string" $digest) (regexMatch "^sha256:[0-9a-f]{64}$" $digest)) -}}
{{- fail (printf "unifesspaGeoApi.image.digest=%q não é um digest sha256 completo" (toString $digest)) -}}
{{- end -}}
{{- $ref = printf "%s@%s" $ref $digest -}}
{{- end -}}
{{- $ref -}}
{{- end -}}
