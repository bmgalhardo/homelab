# argus

Nightly homelab report: collect facts and error logs from the last 24h, ask
Claude what matters, send it to Telegram.
Each report is also stored in Loki as one JSON line under
`{job="argus", mode="sent"}` (`mode="dry"` for `--dry-run`).

Collectors (Loki, Prometheus, Proxmox, Talos via Omni, Home Assistant batteries) are enabled by their
settings in `.env`; leave a block empty to skip it.

## Documentation

The judge reads the homelab's documentation to tell normal from abnormal.
It is fetched at run time, never built into the image:

- `CONTEXT_URLS`: public docs, fetched without auth (the L1 docs from GitHub raw).
- `CONTEXT_PRIVATE_URLS`: private docs, sent `CONTEXT_TOKEN` (known issues
  from the Forgejo context repo, read by a read-only `argus` user).
- `CONTEXT_DIR`: local `*.md` files instead, for development.

Each fetched doc is cached in `CONTEXT_CACHE_DIR`. When a source is down
(e.g. Forgejo during a k8s outage) the run uses the cached copy and adds a
`context_unreachable` fact, which the judge also reads as a sign that host is down.

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

The image is built on athena. Bump the version with every code change
(`uv version --bump patch`) and set the same tag in `docker-compose.yml`.
`docker-compose.yml` mounts `../infra/ca` and a `context-cache` volume, so
mirror the repo layout under `/root`. From the repo root (`argus/.env` only on the
first install; athena keeps its own):

```sh
ssh root@192.168.1.196 'mkdir -p /root/argus /root/infra/ca'
tar -C argus --exclude=.env --exclude=.venv --exclude=__pycache__ \
    --exclude=.pytest_cache --exclude=.ruff_cache -cf - . |
  ssh root@192.168.1.196 'rm -rf /root/argus/src && tar -C /root/argus -xf -'
scp argus/.env root@192.168.1.196:/root/argus/
scp infra/ca/root-ca.crt root@192.168.1.196:/root/infra/ca/
ssh root@192.168.1.196 'cd /root/argus && docker compose build && docker compose run --rm argus --dry-run'
```

The docs come from their URLs on every run: push to update them. To upgrade,
repeat the copy and `docker compose build`.

Schedule it in root's crontab (`crontab -e`):

```
30 3 1-31/2 * * cd /root/argus && docker compose run --rm argus
```
