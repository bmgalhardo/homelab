# Vault Agent — postgres VM. Cert only; the postgres password still lives in
# .env on the VM. Adapted from infra/athena/vault-agent/config.hcl.
#
# RECONSTRUCTED 2026-09-16 — the original was untracked and lost. Review before
# deploying. Vault-side setup: infra/vault/approle-bootstrap.sh roles/postgres.env

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

# Two stanzas with identical secret args share one issued pair — consul-template
# caches the write. ip_sans is required: clients reach postgres by IP as well as
# by name, and the AppRole policy allow-lists exactly this value.
template {
  source      = "/vault-agent/templates/postgres-cert.tpl"
  destination = "/certs/postgres.crt"
  perms       = "0644"
}

template {
  source      = "/vault-agent/templates/postgres-key.tpl"
  destination = "/certs/postgres.key"
  perms       = "0600"
  # postgres refuses to start if the key is group- or world-readable, and it
  # must be owned by the postgres uid. Only root can chown, which is why this
  # container runs as root (see docker-compose.yml).
  command     = "sh -c 'chown 999:999 /certs/postgres.key /certs/postgres.crt && chmod 600 /certs/postgres.key && touch /certs/.reload'"
}
