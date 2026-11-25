{{- /* Nomes fixos dos middlewares criados pelo chart. */ -}}
{{- define "traefik.nomesMiddlewaresFixos" -}}
{{- dict "adminInterno" "uniplus-admin-interno" "compress" "uniplus-compress" "headersSecurity" "uniplus-headers-security" | toJson -}}
{{- end -}}
