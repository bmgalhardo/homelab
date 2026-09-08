# Vault Agent — athena. Reusable sidecar pattern (see README).
# Template for any VM/node service that needs Vault secrets or a leaf cert.
# To adopt elsewhere: copy this file + templates/, change the AppRole
# (role_id/secret_id), the KV path, and the cert common_name.

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

# No API proxy / cache needed — templating only.
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

# ── Cert: pki_infra leaf for athena.bgalhardo.internal (the node hostname) ───
# consul-template caches the issue response, so the two stanzas below share one
# cert/key pair (identical secret args). This is HashiCorp's documented pattern.
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
