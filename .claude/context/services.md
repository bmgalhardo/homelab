# Services & Dependencies

## Outside K8s (VMs on Apollo)

### Vault
- **Location:** Apollo VM (`vault`, reachable via the `hermes` bastion 192.168.1.199)
- **Role:** Secrets management, certificate issuance (PKI, see network.md)
- **HA:** Raft (single node), Shamir seal (1 share/1 threshold), auto-unsealed
  by a sidecar `unsealer` container reading `VAULT_UNSEAL_KEY`
- **Depends on:** None
- **Dependents:** Authentik, Postgres, K8s, all services
- **Backup:** ⚠️ None. No snapshot mechanism exists at all — see todos.md
- **Compose:** Yes — `infra/olympus/services/vault/`, static file (Ansible
  retired 2026-08-21). Listener config in `vault.hcl` (same dir)
- **K8s integration:** kubernetes auth method, `cert_manager` and
  `vault-secrets-operator` policies/roles configured via
  `infra/vault/k8s-auth-bootstrap.sh` (idempotent, safe to re-run).
  Vault is NOT in-cluster, so `auth/kubernetes/config` needs an explicit
  `token_reviewer_jwt` from the `vault-auth` SA, and `vault write` replaces
  the whole config object — any hand-edit that omits it silently breaks
  every login. That happened 2025-12-12 → 2026-08-21, breaking
  cert-manager's `vault` Issuer and every VaultSecretsOperator secret
  cluster-wide; fixed by re-running the script (see network.md).
  The script also creates the `vault-ca` Secret in `vault-secrets-operator`
  from `infra/ca/root-ca.crt`. It can't be a `VaultStaticSecret`: VSO needs
  that CA before it can reach Vault at all. Until it exists the
  `VaultConnection` stays unhealthy and nothing syncs.

### Postgres
- **Location:** Apollo VM (`postgres`, 192.168.1.177)
- **Role:** Database backend for Authentik
- **HA:** Standalone
- **Depends on:** None (secrets now via plain `.env` on the VM, not
  Vault injection — Ansible's `vault_kv2_get` step was retired)
- **Dependents:** Authentik, K8s services needing DB
- **Backup:** Local only — `pg_backup` sidecar runs `backup.sh` daily,
  real daily/weekly/monthly retention, but nothing ships it off this VM.
  See todos.md.
- **Compose:** Yes — `infra/olympus/services/postgres/`, static file

### Authentik
- **Location:** Apollo VM (`authentik`)
- **Role:** Identity provider, authentication gateway
- **HA:** Standalone
- **Depends on:** Postgres (by IP, 192.168.1.177 — not DNS), Vault (PKI
  cert only, not secrets injection)
- **Dependents:** Proxmox UI, K8s API (auth provider), Omni (SAML)
- **Backup:** Database only (via Postgres backup, same gap as above)
- **Compose:** Yes — `infra/olympus/services/authentik/`, static file

### Omni
- **Location:** Apollo VM (`omni`)
- **Role:** Talos cluster bootstrap & lifecycle management
- **HA:** Standalone
- **Depends on:** None (but manages K8s); auth via Authentik SAML
- **Dependents:** K8s cluster (talos-control, talos-worker)
- **Backup:** Unknown — not investigated
- **Compose:** Yes — `infra/olympus/services/omni/`, was always a hand-deployed
  static file, never templated by Ansible

### ~~tftp-server~~ — retired 2026-09-08
Apollo VM `tftp` (`192.168.1.172`, vmid 202). Served `undionly.kpxe` for
PXE boot; nothing used it once `netboot` was retired (2026-08-21).
`infra/olympus/services/tftp-server/` + the tfvars block removed; VM
deletion pending (still in the drifted tfstate).

## Inside K8s (elysium, Talos v1.14.0 / k8s v1.37.0 — 3 nodes)

`talos-r5o-rk4` control-plane, `talos-562-ij1` (label `homelab/node=apollo`,
`power=always-on`), `talos-7bu-8ma` (`homelab/node=hades`, `power=managed`).
Reconciled by Flux in three tiers — see `kubernetes/flux/README.md`.
Verified 2026-09-16 with the scoped kubeconfig.

Live namespaces: `ai`, `automation`, `cert-manager`, `external-dns`,
`flux-system`, `immich`, `local-path-storage`, `metallb-system`,
`nginx-gateway`, `system`, `vault-secrets-operator` (+ `kube-*`).

### system namespace
- `homepage`, `pgadmin`, `redis`, `cloudflare-ddns`
- **`couchdb`** (added 2026-09-15) — Obsidian LiveSync backend, exposed on the
  **external** Gateway at `couchdb.bgalhardo.com` for phone sync. It holds a
  *replica*, not the vault: the vault is the markdown on each device, so its
  local-path PVC being unbacked is acceptable — re-seed from a device.
  Must run as uid 5984, see `kubernetes/30-apps/system/README.md`.
- Both Gateway data planes (`internal` .200 / `external` .201, see network.md)

### immich — running
`immich-server` + `immich-ml`. Photos/cache on virtiofs (Hades); the DB lives
on the `postgres` VM and is covered by its `pg_backup` sidecar.

### ai — running
`ollama`, `litellm`, `openwebui`. All three were broken for days by unrelated
faults found 2026-09-15: ollama by the local-path selector bug (38h Pending),
openwebui by an unencoded `@` in its Postgres password inside `DATABASE_URL`
(531 restarts, a misleading symptom that looked like an openwebui bug).

### automation — RBAC only
`automation/claude` ServiceAccount + `claude-readonly` ClusterRole, the scoped
read-only identity for assistants. See CLAUDE.md.

### Parked, not deployed
`kubernetes/30-apps/_parked/`: `home` (Home Assistant), `mediacenter` (plex,
sonarr, radarr, sabnzbd, overseerr), `nvidia`, `gaming`. All declare
`local-path` for `/config` — they grow the unbacked-PVC surface when unparked.

## Outside K8s (athena — Pi4, 192.168.1.196)

The Argus logging/metrics stack, deliberately off the cluster so it survives a
k8s outage. Static docker compose at `/root/athena/`, source `infra/athena/`.

- `loki` (3100), `prometheus` (9090), `grafana` (3000, HTTPS), `alloy`
  (syslog receiver, 1514), `vault-agent`
- **Vault Agent sidecar** — AppRole auth, renders the Grafana admin creds and
  issues the node's TLS leaf. First implementation of the pattern; the
  reference for every other VM.
- **Grafana is stateless** — no `grafana.db` volume. Datasources and dashboards
  are provisioned from files, so the Vault admin password applies on every
  boot rather than only at first init. Dashboards are exported back to files
  with `grafana/export-dashboards.sh`.
- Phase 1 complete 2026-09-14; Phase 2 (shipping logs from every host) not
  started. See `argus.md`.

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

## Dependency Graph

```
Vault (P0 - everything depends)
  ├─→ Authentik (auth provider)
  ├─→ Postgres (Authentik DB)
  ├─→ Omni (K8s manager)
  └─→ K8s (cert-manager)

Hermes DNS/LB (independent, P0 - service discovery)
  ├─→ dnsmasq (all services need DNS)
  └─→ HAProxy (proxmox.*, postgres.* entries)

Hades NFS (SPOF - all K8s services depend)
  ├─→ K8s (Immich, HA, Plex storage)
  └─→ Immich, Plex, Home Assistant

Apollo LXC Corosync (voting node)
  └─→ Proxmox cluster quorum (2-node)
```

## Single Points of Failure

⚠️ **Vault** — All services depend; requires backup
⚠️ **Postgres** — Authentik depends; requires backup
⚠️ **Hades NFS** — K8s storage; only NFS provider
⚠️ **Apollo** — K8s control plane single-node (not HA)
⚠️ **Hermes DNS** — No backup (future: Pi4 backup dnsmasq)
