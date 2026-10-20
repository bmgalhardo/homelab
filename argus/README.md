# argus

Nightly homelab report: collect facts and error logs from the last 24h, ask
Claude what matters, send it to Telegram.
Each report is also stored in Loki as one JSON line under
`{job="argus", mode="sent"}` (`mode="dry"` for `--dry-run`).

Collectors (Loki, Prometheus, Proxmox, Talos via Omni) are enabled by their
settings in `.env`; leave a block empty to skip it.

## Local

```sh
cp .env.example .env   # fill in tokens
uv sync
uv run argus --dry-run # logs the report instead of sending it
uv run argus --dry-run --no-batch  # direct call: full price, no batch wait
uv run pytest
```

In a container (`uv.lock` must exist):

```sh
docker compose build
docker compose run --rm argus --dry-run
```

## athena

CI (`.github/workflows/argus.yml`) builds `ghcr.io/bmgalhardo/argus` for
amd64 + arm64 on every push to `main` that touches `argus/`, tagged with the
`pyproject.toml` version and the commit SHA. Bump the version with every code
change (`uv version --bump patch`) and set the same tag in
`docker-compose.yml`; CI refuses to republish an existing version.
`docker-compose.yml` mounts `../.claude/context` and `../infra/ca`, so mirror
the repo layout under `/root`. From the repo root:

```sh
ssh root@192.168.1.196 'mkdir -p /root/argus /root/.claude /root/infra/ca'
scp argus/docker-compose.yml argus/.env root@192.168.1.196:/root/argus/
scp -r .claude/context root@192.168.1.196:/root/.claude/
scp infra/ca/root-ca.crt root@192.168.1.196:/root/infra/ca/
ssh root@192.168.1.196 'cd /root/argus && docker compose run --rm argus --dry-run'
```

Re-run the context `scp` after editing the docs. To upgrade, copy the
`docker-compose.yml` with the new tag; the next run pulls it.

Schedule it in root's crontab (`crontab -e`):

```
30 3 1-31/2 * * cd /root/argus && docker compose run --rm argus
```
