{{- with secret "kv/data/athena" -}}
PROXMOX_TOKEN_SECRET={{ .Data.data.proxmox_token_secret }}
OMNI_SERVICE_ACCOUNT_KEY={{ .Data.data.OMNI_SERVICE_ACCOUNT_KEY }}
{{- with .Data.data.ha_token }}
HA_TOKEN={{ . }}
{{- end }}
{{- with .Data.data.context_token }}
CONTEXT_TOKEN={{ . }}
{{- end }}
{{- end }}
