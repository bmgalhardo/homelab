{{- with secret "kv/data/athena" -}}
GF_SECURITY_ADMIN_USER={{ .Data.data.grafana_admin_user }}
GF_SECURITY_ADMIN_PASSWORD={{ .Data.data.grafana_admin_password }}
{{- end }}
