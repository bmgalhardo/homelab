{{- with secret "pki_infra/issue/internal" "common_name=postgres.bgalhardo.internal" "ip_sans=192.168.1.177" "ttl=360h" -}}
{{ .Data.private_key }}
{{- end -}}
