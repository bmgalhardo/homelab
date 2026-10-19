{{- with secret "pki_infra/issue/internal" "common_name=athena.bgalhardo.internal" "ttl=2160h" -}}
{{ .Data.private_key }}
{{- end -}}
