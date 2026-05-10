{{/*
  Helpers do chart wrapper Uni+ para Grafana.
  Apenas templates locais (IngressRoute, Middleware) — o subchart
  grafana/grafana traz seus próprios fullname/labels para as resources
  upstream (Deployment, Service, etc.).
*/}}

{{- define "grafana.fullname" -}}
{{- printf "%s-grafana" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
