{{- with secret "kv/data/athena" -}}
{{ .Data.data.homeassistant_token }}
{{- end }}
