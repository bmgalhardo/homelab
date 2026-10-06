{{- with secret "kv/data/athena" -}}
{{ .Data.data.unifi_api_key }}
{{- end }}
