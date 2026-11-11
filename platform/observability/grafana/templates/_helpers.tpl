{{/*
  Nome base dos recursos do wrapper. Não pode se chamar `grafana.fullname`:
  os templates do Helm são globais e o nome colidiria com o helper do
  subchart, renomeando o Service dele.
*/}}
{{- define "uniplus-grafana.fullname" -}}
{{- printf "%s-grafana" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
  Nome do Service do subchart: o helper dele usa a release como está quando
  ela já contém o nome do chart, e `<release>-grafana` caso contrário.
*/}}
{{- define "uniplus-grafana.serviceName" -}}
{{- if contains "grafana" .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-grafana" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
