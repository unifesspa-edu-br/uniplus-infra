{{/* Fullname com truncate DNS-1123. */}}
{{- define "uniplusApiHost.fullname" -}}
{{- if .Values.uniplusApiHost.fullnameOverride -}}
{{- .Values.uniplusApiHost.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.uniplusApiHost.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uniplusApiHost.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.uniplusApiHost.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uniplusApiHost.labels" -}}
{{ include "uniplusApiHost.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{- define "uniplusApiHost.serviceAccountName" -}}
{{- if .Values.uniplusApiHost.serviceAccount.create -}}
{{- default (printf "%s-sa" (include "uniplusApiHost.fullname" .)) .Values.uniplusApiHost.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.uniplusApiHost.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/* Nomes dos Secrets sintetizados pelo ESO. */}}
{{- define "uniplusApiHost.postgresSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-postgres
{{- end -}}

{{- define "uniplusApiHost.redisSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-redis
{{- end -}}

{{- define "uniplusApiHost.kafkaSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-kafka
{{- end -}}

{{- define "uniplusApiHost.minioSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-minio
{{- end -}}

{{- define "uniplusApiHost.oidcSecretName" -}}
{{ include "uniplusApiHost.fullname" . }}-oidc-client
{{- end -}}

{{/*
Variáveis de ambiente do processo da api.

Compartilhadas entre o Deployment e o Job de migration (ADR-0127 do uniplus-api):
os dois sobem a MESMA imagem e o composition root valida a configuração inteira no
boot, então o Job precisa das mesmas variáveis do Deployment — o que muda entre
eles é só o papel, declarado em `UniPlus__Migrations__Mode`.

Manter isso num único lugar é o que impede o Job de divergir do Deployment em
silêncio, que seria descoberto só quando a migration falhasse por configuração
faltando.
*/}}
{{/*
Variáveis de ambiente do processo da api.

Compartilhadas entre o Deployment e o Job de migration (ADR-0127 do uniplus-api):
os dois sobem a MESMA imagem, e o composition root valida a configuração inteira
no boot — então o Job precisa das mesmas variáveis do Deployment. O que muda
entre eles é só o papel, declarado em `UniPlus__Migrations__Mode`.

Manter isso num lugar só é o que impede o Job de divergir do Deployment em
silêncio, divergência que seria descoberta apenas quando a migration falhasse
por configuração faltando — no pior momento possível.

A indentação aqui é RELATIVA: quem inclui aplica o `nindent` do seu contexto.
Por isso o `toYaml` de `extraEnv` usa `nindent 0` — com 12, somaria à
indentação do include e produziria itens fora da lista.
*/}}
{{- define "uniplusApiHost.env" -}}
# === ASP.NET Core base ===
- name: ASPNETCORE_ENVIRONMENT
  value: {{ .Values.uniplusApiHost.aspnet.environment | quote }}
- name: ASPNETCORE_URLS
  value: {{ .Values.uniplusApiHost.aspnet.urls | quote }}
# === Postgres — banco único `uniplus`, schema-por-módulo (ADR-0097).
# As 7 connection strings (UniPlusDb/ConfiguracaoDb/OrganizacaoDb/
# SelecaoDb/IngressoDb/PublicacoesDb/DiscentesDb) apontam para o
# MESMO host/database/role — cada DbContext usa seu próprio schema
# via HasDefaultSchema. UniPlusDb é consumida pelo outbox Wolverine
# (schema `wolverine`) e pelos health checks
# (AddUniPlusHealthChecks connectionStringName). ===
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.postgresSecretName" . }}
      key: POSTGRES_PASSWORD
{{- $db := .Values.uniplusApiHost.database }}
{{- range list "UniPlusDb" "ConfiguracaoDb" "OrganizacaoDb" "SelecaoDb" "IngressoDb" "PublicacoesDb" "DiscentesDb" }}
- name: ConnectionStrings__{{ . }}
  value: "Host={{ $db.host }};Port={{ $db.port }};Database={{ $db.name }};Username={{ $db.username }};Password=$(POSTGRES_PASSWORD)"
{{- end }}
# === Redis (Connection string formato StackExchange.Redis) ===
- name: REDIS_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.redisSecretName" . }}
      key: REDIS_PASSWORD
- name: Redis__ConnectionString
  value: "{{ .Values.uniplusApiHost.redis.host }}:{{ .Values.uniplusApiHost.redis.port }},user={{ .Values.uniplusApiHost.redis.username }},password=$(REDIS_PASSWORD)"
# === Kafka — BootstrapServers SEMPRE setado (nunca omitido). O host
# lê via string.IsNullOrWhiteSpace em dois pontos independentes
# (WolverineOutboxConfiguration + SelecaoMessagingRegistration no
# uniplus-api) — " " (espaço) é tratado como "vazio" por essa
# checagem, desligando o transporte Kafka de forma limpa sem
# disparar a validação fatal "Kafka:BootstrapServers populado mas
# SchemaRegistry:Url vazio" (ADR-0051). Mesma receita documentada em
# uniplus-api/docker/docker-compose.monolito.yml e já replicada em
# apps/uniplus-api-portal/templates/deployment.yaml (issue #423).
# Omitir a env var por completo (como ainda fazem os charts legados
# uniplus-api-{selecao,ingresso}, mantidos só para standalone-compact)
# NÃO é equivalente aqui: description completa no values.yaml.
- name: Kafka__BootstrapServers
  value: {{ if .Values.uniplusApiHost.kafka.enabled }}{{ .Values.uniplusApiHost.kafka.bootstrapServers | quote }}{{ else }}" "{{ end }}
{{- if .Values.uniplusApiHost.kafka.enabled }}
- name: Kafka__SecurityProtocol
  value: {{ .Values.uniplusApiHost.kafka.securityProtocol | quote }}
- name: Kafka__SaslMechanism
  value: {{ .Values.uniplusApiHost.kafka.saslMechanism | quote }}
- name: Kafka__SaslUsername
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.kafkaSecretName" . }}
      key: KAFKA_USERNAME
- name: Kafka__SaslPassword
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.kafkaSecretName" . }}
      key: KAFKA_PASSWORD
- name: Kafka__SslCaLocation
  value: {{ .Values.uniplusApiHost.kafka.caCertPath | quote }}
{{- end }}
# === MinIO (Storage:* binding) ===
- name: MINIO_ACCESS_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.minioSecretName" . }}
      key: MINIO_ACCESS_KEY
- name: MINIO_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.minioSecretName" . }}
      key: MINIO_SECRET_KEY
- name: Storage__Endpoint
  value: {{ .Values.uniplusApiHost.storage.endpoint | quote }}
- name: Storage__AccessKey
  value: "$(MINIO_ACCESS_KEY)"
- name: Storage__SecretKey
  value: "$(MINIO_SECRET_KEY)"
- name: Storage__BucketName
  value: {{ .Values.uniplusApiHost.storage.bucketName | quote }}
{{- if .Values.uniplusApiHost.oidc.enabled }}
# === OIDC (Auth:* binding — bearer validation apenas; o host não
# se autentica como client M2M contra nada — Schema Registry/Kafka
# ficam desligados nesta leva, então não há client_secret a injetar). ===
- name: Auth__Authority
  value: {{ .Values.uniplusApiHost.oidc.issuerUri | quote }}
- name: Auth__Audience
  value: {{ .Values.uniplusApiHost.oidc.audience | quote }}
{{- end }}
# === Cifragem (UniPlus:Encryption) ===
# Provider=local exige LocalKey via env/Secret; Provider=vault exige
# VaultAddress + KubernetesRole bound à ServiceAccount deste Deployment.
- name: UniPlus__Encryption__Provider
  value: {{ .Values.uniplusApiHost.encryption.provider | quote }}
{{- if eq .Values.uniplusApiHost.encryption.provider "vault" }}
- name: UniPlus__Encryption__VaultAddress
  value: {{ .Values.uniplusApiHost.encryption.vaultAddress | quote }}
- name: UniPlus__Encryption__KubernetesRole
  value: {{ .Values.uniplusApiHost.encryption.kubernetesRole | quote }}
{{- end }}
# === Schema Registry (ADR-0051) — Apicurio Confluent-compat ===
# url vazio = feature off (default no lab — issue #423). AuthType
# OAuthBearer exige tokenEndpoint+clientId; client_secret vem do
# ESO 5 (oidcSecretName).
{{- if .Values.uniplusApiHost.schemaRegistry.url }}
- name: SchemaRegistry__Url
  value: {{ .Values.uniplusApiHost.schemaRegistry.url | quote }}
- name: SchemaRegistry__AuthType
  value: {{ .Values.uniplusApiHost.schemaRegistry.authType | quote }}
{{- if eq .Values.uniplusApiHost.schemaRegistry.authType "OAuthBearer" }}
- name: SchemaRegistry__OAuth__TokenEndpoint
  value: {{ .Values.uniplusApiHost.schemaRegistry.oauth.tokenEndpoint | quote }}
- name: SchemaRegistry__OAuth__ClientId
  value: {{ .Values.uniplusApiHost.schemaRegistry.oauth.clientId | quote }}
- name: SchemaRegistry__OAuth__ClientSecret
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.oidcSecretName" . }}
      key: OIDC_CLIENT_SECRET
{{- end }}
{{- end }}
{{- if .Values.uniplusApiHost.otel.enabled }}
# === OpenTelemetry (ADR-0018) ===
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: {{ .Values.uniplusApiHost.otel.exporter.endpoint | quote }}
- name: OTEL_EXPORTER_OTLP_PROTOCOL
  value: {{ .Values.uniplusApiHost.otel.exporter.protocol | quote }}
{{- if .Values.uniplusApiHost.otel.resource.serviceName }}
- name: OTEL_SERVICE_NAME
  value: {{ .Values.uniplusApiHost.otel.resource.serviceName | quote }}
{{- end }}
{{- else }}
- name: Observability__Enabled
  value: "false"
{{- end }}
{{- range $i, $origin := .Values.uniplusApiHost.cors.allowedOrigins }}
- name: Cors__AllowedOrigins__{{ $i }}
  value: {{ $origin | quote }}
{{- end }}
{{- with .Values.uniplusApiHost.extraEnv }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- end }}
