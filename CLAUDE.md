# Homelab Atlas - Project Instructions

## What This Is

2-node Proxmox cluster (Olympus) running K8s and VMs.
Domain: `bgalhardo.internal`
Network: `192.168.1.0/24`

**Nodes:**
- **Apollo (197)** — Beelink S12 Pro, always-on. Proxmox host + K8s control/worker + corosync LXC
- **Hades (198)** — Ryzen 5 PC, power-managed. Proxmox host + NAS (NFS)
- **Hermes (199)** — Pi B+ (Alpine), power-managed. DNS + load balancer (independent)

## Key Facts

| Aspect | Status |
|--------|--------|
| **Cluster** | 2-node + Apollo LXC qdevice |
| **K8s** | Single control plane (not HA) |
| **Deployment** | Static Docker Compose per VM (Ansible retired 2026-08-21) |
| **DNS** | dnsmasq on Hermes (independent) |
| **Storage** | virtiofs from Hades for k8s media/photos; `local-path` on a dedicated per-node disk for PVCs (NFS retired at the elysium rebuild) |
| **Certificates** | Vault-managed, *.bgalhardo.internal |

## Documentation

**Quick Reference:** Start in `.claude/context`
- `hardware.md` — Rack layout, specs, devices
- `network.md` — IPs, DNS, VLANs
- `services.md` — What runs where, dependencies
- `storage.md` — NFS, backups, snapshots
- `deployment.md` — How to deploy (static compose per VM, no Ansible)
- `backup-strategy.md` — 3-2-1 plan, RTO/RPO
- `todos.md` — Actions, blockers, priorities
- `argus.md` — Centralized logging + daily report agent (design & progress)

See `.claude/context/todos.md` for full roadmap.

## Access for assistants/automation

**Use the scoped kubeconfig, not the admin context:**

```sh
export KUBECONFIG=.claude/secrets/kube-claude.yaml
```

`~/.kube/config` is the human Omni OIDC identity with **full cluster-admin**.
The scoped one is a ServiceAccount (`automation/claude`) that is read-only and
cannot read Secrets, exec into pods, or mutate anything. Identity declared in
`kubernetes/20-infra-wiring/rbac-claude.yaml`; regenerate the kubeconfig with
`infra/elysium/make-claude-kubeconfig.sh`.

Ask before doing anything the scoped identity cannot do — don't reach for the
admin context to work around a Forbidden.

**Do not commit or push.** Leave changes in the working tree — the user
reviews and commits. This holds even when the change is needed for a GitOps
reconcile; say so and let the user push.

**What RBAC does not protect**, so don't rely on it alone:
- pod **logs** and pod **env vars** leak credentials the app puts there
- shell access reads any file the user can read (`.claude/secrets/*`, Vault
  tokens, `.env` files)

The durable fix for the first one is keeping credentials out of pod specs —
use `secretKeyRef`, never an inline password in `env:`.

## Conventions

**Code & Config:**
- **Manifests and configs are not a logbook.** Keep YAML/HCL to the config
  itself. No rationale, no incident history, no dated notes, no "do not
  re-add X because Y". A comment earns its place only when the line is
  actively misleading without it — and then it is one line.
  Rationale belongs in the directory's `README.md`; incidents, decisions and
  root causes belong in `.claude/context/`. Same rule this file states about
  itself: keep it small, reference detailed docs, don't duplicate.
- Terraform for VM provisioning (`infra/{olympus,elysium}/terraform`)
- Static Docker Compose per VM for services (`infra/olympus/services/<name>/`)
- K8s manifests in `kubernetes/`
- **Any app or service with an `HTTPRoute` also gets an entry in the homepage
  dashboard** (`kubernetes/30-apps/system/homepage.yaml`, `services.yaml`):
  `icon`, `href` (the public hostname), and `siteMonitor` (the in-cluster
  `http://<service>.<namespace>[:port]`). Adding the route without the tile
  means the app exists but nothing links to it.
- No sensitive data in git — `.env` per VM (gitignored), Vault for
  everything else. See `.gitignore` before adding anything under `infra/`

**File Organization:**
- `infra/olympus/terraform/` — Proxmox VM provisioning (vault, authentik,
  postgres, omni)
- `infra/elysium/terraform/` — Talos k8s cluster VM provisioning.
  `infra/hal9000/` is the retired predecessor — VMs stopped, not yet destroyed
- `infra/olympus/services/` — static `docker-compose.yml` per VM service
- `infra/athena/` — Argus logging/metrics stack (Pi4 node)
- `infra/vault/` — Vault-side AppRole/policy bootstrap. Talks only to Vault,
  never shipped to a node; one parameterised script + `roles/<service>.env`
- `infra/ca/` — internal root CA certificate. Public, committed deliberately
  (the *private* key stays in Vault)
- `infra/hermes/` — DNS + LB configs (Pi 1, native Alpine, not compose).
  **Also the SSH bastion** — `manager` (192.168.1.170) was deleted 2026-09-14;
  hermes holds the root keyring and is the only host a workstation can reach
- `kubernetes/` — k8s manifests for elysium, reconciled by Flux in three
  tiers: `10-infra-base` → `20-infra-wiring` → `30-apps`. A thing belongs in
  tier 2 if tier 1 has to install its CRD first. See `kubernetes/flux/README.md`

**Naming:** Greek pantheon. `olympus` = Proxmox cluster (Apollo, Hades).
`elysium` (was `hal9000`) = k8s, the plane above. `hermes`/`athena` =
standalone Pis. `manager` was deleted 2026-09-14 (bastion role → hermes).
Possible later: `qdevice` → `themis`.

## When to Update This File

- Architecture changes (node additions, network changes)
- New P0 blockers
- Major decision points
- **NOT:** Day-to-day operational updates (those go in context/)

Keep this file small. Reference detailed docs, don't duplicate.
