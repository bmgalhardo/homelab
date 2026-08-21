# Services & Dependencies

## Outside K8s (VMs on Apollo)

### Vault
- **Location:** Apollo VM (`vault`, reachable via `manager` 192.168.1.170)
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
  `infra/olympus/services/vault/bootstrap-k8s-auth.sh` (idempotent, safe
  to re-run). Vault is NOT in-cluster, so `auth/kubernetes/config` needs
  an explicit `token_reviewer_jwt` — see script header. This was silently
  missing 2025-12-12 → 2026-08-21, breaking cert-manager's `vault` Issuer
  and every VaultSecretsOperator secret cluster-wide; fixed by re-running
  the bootstrap script (see network.md).

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

### tftp-server
- **Location:** Apollo VM (`tftp`, 192.168.1.172)
- **Role:** PXE boot support (serves `undionly.kpxe` via TFTP)
- **Depends on:** None
- **Dependents:** Netboot workflow (whatever still uses it)
- **Compose:** No — native `apk install tftp-hpa`, not containerized.
  Setup steps: `infra/olympus/services/tftp-server/README.md`
- **Note:** Distinct from `netboot` (a separate VM, retired 2026-08-21 —
  see network.md for its cert revocation)

## Inside K8s (hal9000, Talos — 2 nodes: talos-y43-va4 control-plane,
talos-y6i-w43 worker)

Live namespaces as of 2026-08-21: `cert-manager`, `default`,
`external-dns`, `home`, `immich`, `longhorn-system`, `metallb-system`,
`nginx-gateway`, `system`, `vault-secrets-operator` (+ the 4 standard
`kube-*`). Confirmed by listing pods directly, not from manifests.

### Home Assistant — running (ns `home`)
- Storage: Longhorn (see storage.md — single-node, no redundancy)
- Also in `home`: `mosquitto` (MQTT broker), `hass-mqtt-device-healthcheck`

### Immich — running (ns `immich`)
- `immich-server` (StatefulSet) + `immich-ml`, both healthy

### system namespace — running
- `homepage`, `pgadmin`, `redis`, `cloudflare-ddns`, plus the
  `internal-nginx`/`external-nginx` Gateway data planes (see network.md)
- `mongo` has a manifest (`kubernetes/system/mongo.yml`) and an orphaned
  Longhorn-backed PVC (`data-mongo-0`) but **no live StatefulSet** —
  manifest exists, never applied or since removed. Not investigated
  further this session.

### ⚠️ Manifests with no live match
`kubernetes/mediacenter/` (plex, sonarr, radarr, prowlarr, sabnzbd,
overseerr), `kubernetes/monitoring/` (grafana, mimir, loki, alloy,
exporters), `kubernetes/gaming/` (valheim), `kubernetes/nvidia/`
(device plugin) — full manifests exist in git, confirmed 2026-08-21 via
`kubectl get deploy,statefulset,daemonset -A` that **none of them are
deployed**: no matching namespaces, pods, or RuntimeClasses anywhere in
the cluster. Either decommissioned without cleaning up git, or written
but never applied — not determined this session. There is currently no
metrics/logs stack running in this cluster at all.

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
- **Location:** Apollo LXC (Alpine)
- **Role:** Cluster quorum voting (2-node: Apollo + Hades)
- **Depends on:** Apollo (always-on)
- **Dependents:** Proxmox cluster voting
- **Status:** To be migrated from Hermes Pi

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
