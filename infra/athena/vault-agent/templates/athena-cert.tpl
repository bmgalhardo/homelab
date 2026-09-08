{{- with secret "pki_infra/issue/internal" "common_name=athena.bgalhardo.internal" "ttl=360h" -}}
{{ .Data.certificate }}
{{ .Data.issuing_ca }}
{{- end -}}
