# Vault Agent — athena.

pid_file = "/vault-agent/pidfile"

vault {
  address = "https://vault.bgalhardo.internal"
  ca_cert = "/vault-agent/ca.crt"
  retry {
    num_retries = 5
  }
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/vault-agent/role_id"
      secret_id_file_path                 = "/vault-agent/secret_id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/vault-agent/.vault-token"
      mode = 0640
    }
  }
}

template_config {
  static_secret_render_interval = "5m"
  exit_on_retry_failure         = false
}

# ── Secrets: KV v2 at kv/athena -> env file for Grafana ─────────────────────
template {
  source      = "/vault-agent/templates/grafana-env.tpl"
  destination = "/secrets/grafana.env"
  perms       = "0640"
  command     = "sh -c 'touch /certs/.reload'"
}

# ── Cert: pki_infra leaf for athena.bgalhardo.internal ──────────────────────
# identical secret args → one issued cert/key pair (consul-template caches the write)
template {
  source      = "/vault-agent/templates/athena-cert.tpl"
  destination = "/certs/athena.crt"
  perms       = "0644"
}

template {
  source      = "/vault-agent/templates/athena-key.tpl"
  destination = "/certs/athena.key"
  perms       = "0640"
  command     = "sh -c 'touch /certs/.reload'"
}
