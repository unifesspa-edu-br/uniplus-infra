{{/*
Nome curto do release. Sem peculiaridades de naming; pattern padrão Helm
(release.Chart) com truncate p/ DNS-1123.
*/}}
{{- define "minioConsoleProxy.fullname" -}}
{{- if .Values.minioConsoleProxy.fullnameOverride -}}
{{- .Values.minioConsoleProxy.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.minioConsoleProxy.nameOverride -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Selector labels (subset estável dos commonLabels — match.io.k.s/name e
match.io.k.s/instance só; version e managed-by mudariam entre releases e
quebrariam selectors se incluídos).
*/}}
{{- define "minioConsoleProxy.selectorLabels" -}}
app.kubernetes.io/name: {{ default .Chart.Name .Values.minioConsoleProxy.nameOverride }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Labels padrão Uni+ + chart info, aplicados a TODOS os recursos do chart.
*/}}
{{- define "minioConsoleProxy.labels" -}}
{{ include "minioConsoleProxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end -}}
{{- end -}}

{{/*
Acervo público (ADR-0132 do uniplus-api) — rota da borda para o bucket
público, independente do Console. Nome próprio para que ligar um não
dependa do outro.
*/}}
{{- define "acervoPublicoProxy.fullname" -}}
{{- if .Values.acervoPublicoProxy.fullnameOverride -}}
{{- .Values.acervoPublicoProxy.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-acervo-publico" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "acervoPublicoProxy.selectorLabels" -}}
app.kubernetes.io/name: acervo-publico-proxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Sem `commonLabels` do chart: ele traz `component: data-admin`, que descreve o
Console e colidiria com o `component` declarado aqui.
*/}}
{{- define "acervoPublicoProxy.labels" -}}
{{ include "acervoPublicoProxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: uniplus
app.kubernetes.io/component: acervo-publico
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Porta de dados do MinIO sob nome próprio, para as URLs assinadas devolvidas ao
navegador. Nome e labels próprios, pelo mesmo motivo do acervo.
*/}}
{{- define "portaDeDadosProxy.fullname" -}}
{{- if .Values.portaDeDadosProxy.fullnameOverride -}}
{{- .Values.portaDeDadosProxy.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-porta-de-dados" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "portaDeDadosProxy.selectorLabels" -}}
app.kubernetes.io/name: porta-de-dados-proxy
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "portaDeDadosProxy.labels" -}}
{{ include "portaDeDadosProxy.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: uniplus
app.kubernetes.io/component: porta-de-dados
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Service ClusterIP sem selector + EndpointSlice manual para uma porta do MinIO no
host, fora do cluster. Comum às rotas deste chart.

Por que não ExternalName: o campo exige FQDN; com IP literal o CoreDNS responde
NXDOMAIN e o Traefik fica sem backend (502). Por que EndpointSlice e não
Endpoints v1: Endpoints está deprecated desde o K8s 1.33. O label
`kubernetes.io/service-name` é o que associa o EndpointSlice ao Service.

Parâmetros (dict): bloco (chave do values, para as mensagens), nome, labels
(já renderizados), host (IPv4 literal) e porta.
*/}}
{{- define "minioProxy.backend" -}}
{{- if not .host -}}
{{- fail (printf "%s.backend.host é obrigatório quando enabled=true (o EndpointSlice precisa do IP do host onde o MinIO escuta; sem ele o Service fica sem endpoint e o Traefik responde 502)." .bloco) -}}
{{- end -}}
{{- if not (regexMatch "^([0-9]{1,3}\\.){3}[0-9]{1,3}$" .host) -}}
{{- fail (printf "%s.backend.host deve ser um IPv4 literal (ex.: 192.168.21.134) — recebido %q. O EndpointSlice declara addressType: IPv4; FQDN é rejeitado pelo apiserver." .bloco .host) -}}
{{- end -}}
apiVersion: v1
kind: Service
metadata:
  name: {{ .nome }}
  labels:
    {{- .labels | nindent 4 }}
spec:
  type: ClusterIP
  ports:
    - name: http
      port: {{ .porta }}
      targetPort: {{ .porta }}
      protocol: TCP
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: {{ .nome }}
  labels:
    {{- .labels | nindent 4 }}
    kubernetes.io/service-name: {{ .nome }}
addressType: IPv4
ports:
  - name: http
    port: {{ .porta }}
    protocol: TCP
endpoints:
  - addresses:
      - {{ .host | quote }}
    conditions:
      ready: true
{{- end -}}
