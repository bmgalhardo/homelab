# athena — logging + metrics stack

Loki + Prometheus + Grafana + an Alloy syslog receiver + a Vault Agent
sidecar. 

- **Node:** `athena` — Pi4, `192.168.1.196`, 4GB, arm64, Alpine on a
  120GB SATA SSD (persistent install). `ssh root@192.168.1.196` via the
  **`hermes` bastion (192.168.1.199)** — `manager` was deleted 2026-09-14. All images are arm64-available.
- **Deploy dir:** `/root/athena/`

| Service | Port | Notes |
|---------|------|-------|
| loki | 3100 | monolithic, filesystem, TSDB, 90d retention |
| prometheus | 9090 | 30d / 2GB retention, scrapes the local stack (host/k8s exporters are stubs) |
| grafana | 3000 | HTTPS, Loki + Prometheus datasources pre-provisioned |
| alloy | 1514 tcp+udp | syslog receiver — Hermes (Pi 1), UDM Pro |
| vault-agent | — | AppRole → renders `secrets/grafana.env` + issues `certs/athena.{crt,key}` |

## First deploy

Docker install

```sh
apk add docker docker-cli-compose
rc-update add docker default && service docker start
```

### Vault side (once — not per rebuild)

Lives in `infra/vault/`, **not here**: it talks only to Vault, and this node
cannot run it (its own token is denied on `auth/approle/role/athena`).

```sh
export VAULT_ADDR=https://vault.bgalhardo.internal
vault login
cd ../vault && ./approle-bootstrap.sh roles/athena.env
```

Creates the `athena` AppRole + policy (read `kv/athena`, issue the
`athena.bgalhardo.internal` leaf cert — nothing else), seeds `kv/athena`
with a random Grafana password, and prints the `role_id` / `secret_id`.

These objects live in Vault and survive a node rebuild. After reprovisioning
you only need a fresh credential, not another bootstrap:
`./approle-bootstrap.sh roles/athena.env --secret-id-only`.

### Host side

```sh
ssh root@athena 'mkdir -p /root/athena'
scp -r infra/athena/* root@athena:/root/athena/
ssh root@athena '
  cd /root/athena &&
  cp .env.example .env &&
  mkdir -p data/loki data/prometheus data/grafana data/alloy secrets certs &&
  chown -R 10001:10001 data/loki &&
  chown -R 65534:65534 data/prometheus &&
  chown -R 472:472     data/grafana &&
  touch secrets/grafana.env
'
# paste the AppRole material printed by the bootstrap:
ssh root@athena '
  echo "<role_id>"   > /root/athena/vault-agent/role_id &&
  echo "<secret_id>" > /root/athena/vault-agent/secret_id &&
  chmod 600 /root/athena/vault-agent/secret_id
'
# root CA so vault-agent can verify Vault TLS (committed, public — see infra/ca/):
scp infra/ca/root-ca.crt root@athena:/root/athena/vault-agent/ca.crt

ssh root@athena 'cd /root/athena && docker compose up -d'

# reload hook (restarts grafana / reloads prometheus after a vault-agent render):
ssh root@athena '
  cp /root/athena/vault-agent/reload.sh /root/athena/reload.sh &&
  ( crontab -l 2>/dev/null; echo "*/5 * * * * /root/athena/reload.sh" ) | crontab -
'
```

vault-agent authenticates within a few seconds and writes
`certs/athena.crt`, `certs/athena.key`, `secrets/grafana.env`. If Grafana
raced ahead with the empty env file, the first cron tick restarts it.

