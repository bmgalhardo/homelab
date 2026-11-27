# Services & Dependencies

## Outside K8s (VMs on Apollo)

### Vault
- **Location:** Apollo VM (`vault`, 192.168.1.173)
- **Role:** Secrets management, certificate issuance (PKI, see network.md)
- **HA:** Raft (single node), Shamir seal (1 share/1 threshold), auto-unsealed
  by a sidecar `unsealer` container reading `VAULT_UNSEAL_KEY`
- **Depends on:** None
- **Dependents:** Authentik, Postgres, K8s, all services
- **Backup:** see the backup plan
- **Compose:** Yes — `infra/olympus/services/vault/`, static file (Ansible
  retired 2026-08-21). Listener config in `vault.hcl` (same dir)
- **K8s integration:** kubernetes auth method, `cert_manager` and
  `vault-secrets-operator` policies/roles configured via
  `infra/vault/k8s-auth-bootstrap.sh` (idempotent, safe to re-run).
  Vault is NOT in-cluster, so `auth/kubernetes/config` needs an explicit
  `token_reviewer_jwt` from the `vault-auth` SA, and `vault write` replaces
  the whole config object — any hand-edit that omits it silently breaks
  every login.
  The script also creates the `vault-ca` Secret in `vault-secrets-operator`
  from `infra/ca/root-ca.crt`. It can't be a `VaultStaticSecret`: VSO needs
  that CA before it can reach Vault at all. Until it exists the
  `VaultConnection` stays unhealthy and nothing syncs.

### Postgres
- **Location:** Apollo VM (`postgres`, 192.168.1.177)
- **Role:** Database backend for Authentik
- **HA:** Standalone
- **Depends on:** None (secrets from `.env` on the VM, see deployment.md)
- **Dependents:** Authentik, Forgejo (k8s), K8s services needing DB
- **Backup:** `pg_backup` sidecar runs `backup.sh` daily, with
  daily/weekly/monthly retention on the VM's disk.
- **Compose:** Yes — `infra/olympus/services/postgres/`, static file

### Authentik
- **Location:** Apollo VM (`authentik`)
- **Role:** Identity provider, authentication gateway
- **HA:** Standalone
- **Depends on:** Postgres (by IP, 192.168.1.177 — not DNS), Vault (PKI
  cert only, not secrets injection)
- **Dependents:** Proxmox UI, K8s API (auth provider), Omni (OIDC), Forgejo (OIDC)
- **Outposts:** only the built-in embedded one; no Docker or Kubernetes-managed
  outposts, so the worker has no Docker socket and runs as UID 1000
- **Backup:** Database, through the Postgres backup
- **Compose:** Yes — `infra/olympus/services/authentik/`, static file

### Omni
- **Location:** Apollo VM (`omni`)
- **Role:** Talos cluster bootstrap & lifecycle management
- **HA:** Standalone
- **Depends on:** None (but manages K8s); auth via Authentik OIDC (application `omni`)
- **Dependents:** K8s cluster (talos-control, talos-worker)
- **Compose:** Yes — `infra/olympus/services/omni/`, was always a hand-deployed
  static file, never templated by Ansible

## Inside K8s (elysium, Talos v1.14.0 / k8s v1.37.0 — 4 nodes)

`talos-r5o-rk4` control-plane, `talos-562-ij1` (label `homelab/node=apollo`,
`power=always-on`), `talos-7bu-8ma` (`homelab/node=hades`, `power=managed`), `talos-pcf-vwh`
(VM 1103 `elysium-hades-gpu`, `homelab/gpu=nvidia`, on Hades, power-managed;
off → node NotReady, `ollama-gpu` and its DaemonSet pods Pending — expected).
The `ai` namespace and `immich-ml` are pinned to Hades (`homelab/node: hades`
in their kustomizations); `immich-server` is pinned to Apollo. Hades off →
the Hades pods Pending (Immich keeps serving, smart search/faces pause) and their probes
failing (503) — expected, not an outage. Hades doesn't power back on by
itself after a mains outage.
Reconciled by Flux in three tiers — see `kubernetes/flux/README.md`.
Verified 2026-09-16 with the scoped kubeconfig.

Live namespaces: `ai`, `automation`, `cert-manager`, `external-dns`,
`flux-system`, `gpu-operator` (GPU Operator + node-feature-discovery),
`immich`, `local-path-storage`, `mediacenter`, `metallb-system`, `monitoring`,
`nginx-gateway`, `system`, `vault-secrets-operator` (+ `kube-*`).

### system namespace
- `homepage`, `pgadmin`, `redis`, `cloudflare-ddns`
- `publish` — nginx with WebDAV writes, `projects.bgalhardo.internal`. Serves the
  latest build, docs and review mocks of each project; the agents on daedalus
  upload with `tools/publish/publish.py` from the workflow repo.
  Reachable from LAN/VPN only; everything on it is rebuildable.
  Content on local-path PVC `publish`.
- Both Gateway data planes (`internal` .200 / `external` .201, see network.md)

### immich — running
`immich-server` on Apollo, library + thumbs/encoded-video on virtiofs `immich`
(Apollo host `/mnt/immich`, LV `pve/immich`). `immich-ml` on Hades, model
cache on `local-path`. Hades `photos-mirror` pulls the library into
`/odin/photos` (see storage.md). The DB lives on the `postgres` VM and is
covered by its `pg_backup` sidecar (local disk only).

### ai — running
`llama-cpp` (CPU, chat + embed containers), `llama-cpp-gpu` (GPU node,
Pending while it's off), `litellm` (gateway, falls back from `qwen-gpu` to CPU
`llama-mini`), `openwebui`. Replaced Ollama 2026-11-02 — see `overmind memory get homelab/ai-poc.md`.
`facefusion` — FaceFusion web UI (`facefusion/facefusion:<ver>-cpu`, Gradio
on 7860) at `facefusion.bgalhardo.internal` (internal gateway, LAN/VPN only),
CPU on Hades. Models, caches and jobs on local-path PVC `facefusion-data`
(downloaded on first use). Uploads capped at 2g on the route.

### trading — new 2026-11-09
`ib-gateway` (`ghcr.io/gnzsnz/ib-gateway`, IB Gateway + IBC), pinned to Apollo.
Paper account only (`TRADING_MODE=paper`); IBC logs in by itself, restarts
daily at 23:45 and logs in again after IBKR's weekly reset. API on
LoadBalancer **192.168.1.203:4002** (`ibgateway.bgalhardo.internal`), forwarded
to the pod's socat port 4004, reachable from LAN/VPN only. Credentials from Vault `kv/apps/ib-gateway` →
`username`, `password`. Client: the `algo-trading` project.

### forgejo — live 2026-11-17
Forgejo 17 (`codeberg.org/forgejo/forgejo:17.0.1-rootless`), pinned to Apollo,
at `git.bgalhardo.internal` (internal gateway, wildcard DNS and certificate).
Git host for the user's personal projects: repos, Git LFS for game assets, the
container registry for private project images, Forgejo Actions. The homelab
repo and Flux stay on GitHub, so the cluster never depends on it.
Database `forgejo` on the Postgres VM (`postgres.bgalhardo.internal`); repos, LFS and packages on a local-path PVC (`forgejo-data`). HTTPS at `git.bgalhardo.internal`; git over SSH through Forgejo's built-in server at `git-ssh.bgalhardo.internal:22` (MetalLB .204 → pod 2222).
Sign-in required to view. SSO through Authentik (OIDC, application slug
`forgejo`): accounts are created only on first Authentik login
(`ALLOW_ONLY_EXTERNAL_REGISTRATION`, username = Authentik username); an existing
local account links by logging in once. The `configure-sso` init container runs
`forgejo migrate` and adds or updates the `authentik` auth source on every
start; it skips when `custom/conf/app.ini` on the data volume doesn't exist yet (first boot of an empty volume).
The pod trusts the internal root CA via `SSL_CERT_DIR` (`kv/infra/root-ca`).
Body cap 10g on the route, for LFS and registry pushes. Secrets from Vault
`kv/apps/forgejo` → `secret_key`, `internal_token`, `jwt_secret`,
`lfs_jwt_secret`, `db_password`, `oidc_client_id`,
`oidc_client_secret`.
Backup: nightly `forgejo dump` CronJob to `backups/` on the PVC, 3 days kept.
No Actions runner yet.

### automation — RBAC only
`automation/claude` ServiceAccount + `claude-readonly` ClusterRole, the scoped
read-only identity for assistants. See AGENTS.md.

### home — migrating (2026-10-18)
`kubernetes/elysium/30-apps/home/`, pinned to Apollo.
- `homeassistant` — `home.bgalhardo.internal` on the `internal` Gateway (LAN/VPN). `/config`
  on local-path PVC `homeassistant-config`; recorder history on the `postgres`
  VM (`homeassistant` DB). Ships at `replicas: 0` until the restore from
  `hades:/odin/backups/home-assistant/` is done.
- `mosquitto` — LoadBalancer **192.168.1.202** (fixed), persistence
  on PVC `mosquitto-data`. Clients outside the cluster: the Shellys (native
  MQTT, plus the `ble2ha.js` script on the Mini PM relaying Govee/BLU
  sensors). Shelly settings + scripts are in git (`infra/mqtt-devices/shelly/`,
  pushed with `apply_shelly.py`).
- Config: `configuration.yaml` and `packages/` come from git
  (`kubernetes/elysium/30-apps/home/config/`, ConfigMaps — a change rolls the pod).
  Integrations, dashboards, registries stay UI-managed in `.storage` on the PVC.
  Recorder URL from Vault `kv/apps/homeassistant` → `recorder_db_url`.
- MQTT device entities are YAML (`packages/mqtt_devices.yaml`), generated from
  `infra/mqtt-devices/devices.yml` — not MQTT discovery, nothing retained on
  the broker. Replaces hass-mqtt-device-healthcheck (2026-10-19).

Not migrated from hal9000 (manifests only in git history, `17e511d^:kubernetes/home/`):
ps5-mqtt, hass-mqtt-device-healthcheck, esphome, node-red, whisper/piper/
openwakeword, babybuddy, kiosk-server.

### mediacenter
`kubernetes/elysium/30-apps/mediacenter/`, every Deployment pinned to Hades
(the media shares are virtiofs on `elysium-hades` only). Hades off → all
Pending, expected. Deployed: `sabnzbd`, `sonarr`, `radarr`, `prowlarr`, at
`<app>.bgalhardo.internal`. `plex.yaml` and `overseerr.yaml` sit in the folder,
not yet listed in its kustomization.
- `sabnzbd` — `/config` on local-path PVC `sabnzbd-config`. Downloads to
  `/downloads/{incomplete,complete}` (virtiofs `downloads`, same disk as
  `movies`, so movie imports hardlink).
- `sonarr` (v5, linuxserver `develop` channel), `radarr`, `prowlarr` —
  stateless. Their state is in the `postgres` VM (`<app>-main`, `<app>-log`,
  owner `<app>`), reached over TLS with `SSL Mode=VerifyFull` against the
  internal root CA (`kv/infra/root-ca`). No `config.xml`: settings come from
  `<APP>__AUTH__*` / `<APP>__POSTGRES__*` env vars, the password from
  `PGPASSWORD`. Vault `kv/apps/<app>` → `api_key`, `db_password`. `/config` is
  an `emptyDir` (posters, logs). A postStart hook on sonarr/radarr refreshes
  every series/movie, which re-downloads metadata and covers.
- `plex` (when listed) — `plex.bgalhardo.com` on the `external` Gateway,
  libraries at `/series` and `/movies`, `/config` on PVC `plex-config`.
- Restore: `plex` and `sabnzbd` have a `restore` init container. When `/config`
  is empty it extracts the newest `plex-*.tar` / `sabnzbd-*.tar` from
  `downloads/.restore/` (Hades `/mnt/movies/Downloads/.restore/`), which holds
  copies of the archives in `/odin/backups/{plex,sabnzbd}/`.

### Parked, not deployed
`kubernetes/elysium/30-apps/_parked/`: `gaming`.

## Outside K8s (athena — Pi4, 192.168.1.196)

The athena logging/metrics stack, deliberately off the cluster so it survives a
k8s outage. Static docker compose at `/root/athena/`, source `infra/athena/`.

- `loki` (3100), `prometheus` (9090, also the remote-write target for
  elysium), `grafana` (3000, HTTPS), `alloy` (syslog receivers: 1515
  RFC3164 for hermes, 1516 Talos, 1517 raw for the UDM), `node_exporter`,
  `blackbox_exporter`, cAdvisor, `vault-agent`
- **Vault Agent sidecar** — AppRole auth, renders the Grafana admin creds and
  issues the node's TLS leaf. First implementation of the pattern; the
  reference for every other VM.
- **Grafana is stateless** — no `grafana.db` volume. Datasources and dashboards
  are provisioned from files, so the Vault admin password applies on every
  boot rather than only at first init. Dashboards are exported back to files
  with `grafana/export-dashboards.sh`.
- **argus** — the nightly report agent, `/root/argus` (root cron 03:30), source
  `argus/`. Each report is a JSON line in Loki:
  `curl -sG http://192.168.1.196:3100/loki/api/v1/query_range --data-urlencode 'query={job="argus", mode="sent"}' --data-urlencode limit=1`
  (add `start=` in ns; the default window is one hour).
- Build status: `overmind memory get homelab/argus.md`.

## Outside K8s (Hermes, Independent)

### dnsmasq
- **Location:** Hermes (Pi B+, Alpine)
- **Role:** DNS resolver for bgalhardo.internal
- **Depends on:** None
- **Dependents:** Everything (critical)
- **Config:** Git (bgalhardo.internal zone records)
- **Backup:** Config in git

### HAProxy
- **Location:** Hermes (Pi B+, Alpine)
- **Role:** L4 load balancer, SSL termination
- **Backends:**
  - proxmox (Apollo/Hades failover)
  - postgres (Apollo VM)
- **Depends on:** None
- **Config:** Git
- **Backup:** Config in git

## Proxmox Cluster Infrastructure

### Corosync QDevice
- **Location:** Apollo LXC `qdevice` (192.168.1.89, Debian — Alpine was
  planned but qnetd setup was simpler on Debian)
- **Role:** 3rd quorum vote for the 2-node cluster (Apollo + Hades).
  `corosync-qnetd` on the LXC, `corosync-qdevice` on both nodes, TCP 5403.
- **Depends on:** Apollo (always-on)
- **Dependents:** Proxmox cluster voting
- **Status:** Set up 2026-09-07 via `pvecm qdevice setup 192.168.1.89`.
  Migrated off the Hermes Pi (Pi re-flashed to Alpine for dnsmasq/HAProxy).
- **Gotchas hit during setup:** `corosync-qdevice` package was missing on
  Apollo/Hades (`corosync-qdevice-net-certutil: command not found`);
  qnetd nssdb must be owned by `coroqnetd:coroqnetd`.
- **Verify:** `pvecm status` → `Total votes: 3`, both nodes `A,V`.
- **Caveat:** LXC runs on Apollo — an Apollo outage takes the qdevice with
  it, so Hades alone can't hold quorum. Still covers the Hades-outage case.

### Cerberus (Protect kiosk)
- **Location:** Apollo LXC `cerberus` (192.168.1.175, Debian 13, unprivileged)
- **Role:** UniFi Protect live view (2 cams) on Apollo's HDMI. go2rtc pulls
  the RTSPS substreams (`rtspx://` = no cert check); cage + Chromium shows
  `stream.html` side by side. iGPU shared via `dev0`/`dev1`, no passthrough.
- **Config:** `infra/olympus/services/cerberus/` — RTSPS tokens in `.env`
- **Depends on:** Apollo, UDM Pro (Protect)
- **Power:** started and stopped by hand as needed, no `onboot`; stopped is normal.
- **Status:** Live 2026-10-06, LXC 105, cam1 only (cam2 not online yet —
  commented out in `go2rtc.yaml` and the kiosk URL). Unprivileged works;
  monitor is on HDMI‑A‑2. Log noise that is harmless: dbus, ALSA, GCM, one
  `Atomic commit failed: busy` at start.
- **Chosen over:** UniFi Viewport (cost), iGPU VM passthrough (HDMI out from
  Gen12 iGPU in a VM is unreliable, host loses console), Protect web UI
  (session expiry).

### Daedalus (remote agents)
- **Location:** Apollo VM 101 (192.168.1.170, 1 vCPU / 2 GB), always on
- **Role:** runs Claude Code remote agents for light work. Anything heavy
  (Blender) is delegated over SSH to hephaestus on Hades.
- **Config:** `infra/daedalus/` — `hephaestus.sh up|down|status` (WoL hades,
  start/stop the VM via the `daedalus@pve!power` token, wait for SSH)
- **Depends on:** Apollo, Proxmox API (via hermes HAProxy)

### Hephaestus (Blender worker)
- **Location:** Hades LXC 106 (192.168.1.176, Debian 13, unprivileged),
  12 cores at `cpuunits 50`, 16 GB RAM (cap, not reserved), `onboot 0`
- **Role:** headless Blender 4.5 LTS (`blender -b --python`) for game assets,
  driven from daedalus. Scripts live in the game repo; inputs go up and
  outputs come back with scp, not git.
- **Config:** `infra/olympus/services/hephaestus/` (pct create + install.sh)
- **CPU only:** the 750 Ti is bound to `vfio-pci` for VM passthrough (VM 102
  `personal`, VM 1103 `elysium-hades-gpu`), so an LXC can't use it. Cycles
  CPU works; EEVEE / viewport rendering won't.
- **RAM:** Hades has 31 GB. VM 102 `personal` (20 GB, GPU) is on-demand only —
  `onboot` off, kept shut, started with `VM_NAME=personal
  infra/daedalus/hephaestus.sh up`. Don't run it alongside a heavy bake:
  20 + 16 + `elysium-hades` 8 GB overcommits Hades.
- **Status:** live 2026-10-07; smoke test (Cycles render + glTF export, scp
  back) passed.

## Dependency Graph

```
Vault (everything depends)
  ├─→ Authentik (auth provider)
  ├─→ Postgres (Authentik DB)
  ├─→ Omni (K8s manager)
  └─→ K8s (cert-manager)

Hermes DNS/LB (independent, service discovery)
  ├─→ dnsmasq (all services need DNS)
  └─→ HAProxy (proxmox.*, postgres.* entries)

Hades virtiofs (media/photos, elysium-hades only)
  ├─→ Immich
  └─→ mediacenter (plex, sabnzbd, sonarr, radarr)

Apollo LXC Corosync (voting node)
  └─→ Proxmox cluster quorum (2-node)
```

