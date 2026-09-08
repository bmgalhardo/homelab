{{- with secret "pki_infra/issue/internal" "common_name=athena.bgalhardo.internal" "ttl=360h" -}}
{{ .Data.private_key }}
{{- end -}}
