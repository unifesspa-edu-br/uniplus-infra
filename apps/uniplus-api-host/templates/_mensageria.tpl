{{/*
  Variáveis de mensageria: Kafka de transporte e registro de esquemas. Entram SÓ
  no Deployment, e não em `uniplusApiHost.env`. O Job de migration sobe em
  `PreSync`, antes de o Sync criar o ExternalSecret da credencial do registro de
  esquemas, e a API confere essa credencial ao montar o processo, antes de olhar
  o modo de migration: um `secretKeyRef` do Job para esse Secret, mesmo
  opcional, derrubaria o processo. A migration só fala com o banco; sem as
  variáveis, o registro de esquemas não é montado e nada é exigido.
*/}}
{{- define "uniplusApiHost.envMensageria" -}}
# === Kafka de transporte. O endereço sempre é definido: um espaço em branco
# desliga o transporte sem acionar a recusa "Kafka preenchido sem registro de
# esquemas". Omitir a variável não é equivalente (ver values.yaml).
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
# === Registro de esquemas (ADR-0051), compatível com o Confluent ===
# Endereço vazio desliga o registro. Com AuthType OAuthBearer, são exigidos o
# endereço do token e o cliente; a credencial vem do ExternalSecret do cliente
# OIDC (oidcSecretName).
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
{{- end -}}

{{/*
  Variáveis do registro de acesso (RegistroDeAcesso:Kafka). Entram SÓ no
  Deployment, e não em `uniplusApiHost.env`, de propósito: o Job de migration
  sobe em `PreSync`, antes de o Sync criar o ExternalSecret da credencial, então
  um `secretKeyRef` dele para o Secret novo nunca resolveria e o sync abortaria
  sem criar o próprio Secret. O Job também não precisa delas: em `ApplyAndExit`
  o host é construído mas não iniciado, e a validação das opções e o produtor
  do registro só rodam na partida do servidor.
*/}}
{{- define "uniplusApiHost.envRegistroDeAcesso" -}}
{{- $ra := .Values.uniplusApiHost.registroDeAcesso.kafka }}
# === Registro de acesso (RegistroDeAcesso:Kafka) — independe de kafka.enabled.
- name: RegistroDeAcesso__Kafka__BootstrapServers
  value: {{ $ra.bootstrapServers | quote }}
- name: RegistroDeAcesso__Kafka__Topico
  value: {{ $ra.topico | quote }}
- name: RegistroDeAcesso__Kafka__SecurityProtocol
  value: {{ $ra.securityProtocol | quote }}
- name: RegistroDeAcesso__Kafka__SaslMechanism
  value: {{ $ra.saslMechanism | quote }}
- name: RegistroDeAcesso__Kafka__Usuario
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.registroDeAcessoKafkaSecretName" . }}
      key: KAFKA_USERNAME
- name: RegistroDeAcesso__Kafka__Senha
  valueFrom:
    secretKeyRef:
      name: {{ include "uniplusApiHost.registroDeAcessoKafkaSecretName" . }}
      key: KAFKA_PASSWORD
- name: RegistroDeAcesso__Kafka__CaminhoDoCertificadoCa
  value: {{ $ra.caCertPath | quote }}
{{- if $ra.prazoDeConfirmacao }}
- name: RegistroDeAcesso__Kafka__PrazoDeConfirmacao
  value: {{ $ra.prazoDeConfirmacao | quote }}
{{- end }}
{{- end -}}
