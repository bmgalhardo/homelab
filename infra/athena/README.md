# athena — logging + metrics stack

Loki + Prometheus + Grafana + an Alloy syslog receiver + a Vault Agent
sidecar. The queryable substrate the **Argus** report agent reads (the
agent itself is repo-root `argus/`, Phase 3).

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

`mem_limit` on every container (64/512/384/256/128 MiB, ~1.4 GiB ceiling —
comfortable on the 4GB Pi).

## First deploy

Docker install (done 2026-09-08):

```sh
apk add docker docker-cli-compose
rc-update add docker default && service docker start
```

### Vault side (once — not per rebuild)

Lives in `infra/vault/`, **not here**: it talks only to Vault, and this node
cannot run it (its own token is denied on `auth/approle/role/athena`).

```sh
export VAULT_ADDR=https://vault.bgalhardo.internal   # NOT :8200 — plain HTTP
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

## Verify (Phase 1 exit check)

```sh
curl -s http://athena:3100/ready
curl -s http://athena:9090/-/healthy

# write + read a Loki test stream
curl -s -H 'Content-Type: application/json' -XPOST http://athena:3100/loki/api/v1/push \
  --data-raw '{"streams":[{"stream":{"job":"smoke"},"values":[["'"$(date +%s)000000000"'","hello from athena"]]}]}'
curl -s -G http://athena:3100/loki/api/v1/query_range \
  --data-urlencode 'query={job="smoke"}' | grep -q 'hello from athena' && echo OK

openssl s_client -connect athena:3000 -servername athena.bgalhardo.internal </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -enddate
```

Then `https://athena.bgalhardo.internal:3000` → Explore.

## Vault Agent as a template

The Olympus VMs have no Vault auth today (services read plaintext `.env`).
This `vault-agent/` is the reference for fixing that — it unblocks the P3
"periodic rotation for all secrets" item. To adopt in another service:

1. Copy `vault-agent/` into that service dir (config + templates only —
   the bootstrap is centralised in `infra/vault/`).
2. Add a role file at `infra/vault/roles/<service>.env` and run
   `./approle-bootstrap.sh roles/<service>.env`.
3. In `vault-agent/config.hcl` + `templates/`: change the KV path, the
   cert `common_name`, and the destination files.
4. Add the `vault-agent` service block to that `docker-compose.yml`, and
   point the real service at `./secrets/<x>.env` (env_file) and
   `./certs/` (volume).
5. Copy `reload.sh`, adjust which containers it restarts, add the cron.

Design notes:
- **AppRole**, not k8s auth — these are VMs / bare nodes. `role_id` is not
  secret; `secret_id` is non-expiring (`secret_id_ttl=0`) bootstrap
  material, scoped to a one-path policy. Strictly better than plaintext
  `.env`, and it makes the actual secrets rotatable.
- **Cert renewal**: two template stanzas with identical `secret` args
  share one issued pair (consul-template caches the write) — HashiCorp's
  documented pattern.
- **Reload**: vault-agent touches `certs/.reload`; a host cron restarts
  consumers. Keeps the Docker socket out of the vault-agent container.
  Grafana can't hot-reload TLS, so a restart is unavoidable.
- **Phase 5** moves the `secret_id` itself into a tighter delivery
  (response-wrapped, short TTL) — fine as-is for now.

## Notes

- `athena` = the node and this stack. `argus` = the project/mission — the
  report agent (repo-root `argus/`), the logbook, `.claude/context/argus.md`.
- Image tags pinned to knowledge-cutoff versions (`loki:3.3.2`,
  `prometheus:v3.1.0`, `grafana:11.4.0`, `alloy:v1.5.1`). Check for newer
  patches when revisiting; if a tag 404s on pull, that's why.
- `data/`, `secrets/`, `certs/`, and the vault-agent creds are gitignored.
- Phase 2 repoints `kubernetes/monitoring/alloy/` `loki.write` at
  `http://192.168.1.196:3100` — IP, not DNS (keep DNS out of the ingestion
  path, see argus.md).
