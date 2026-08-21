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
| **Storage** | NFS from Hades for K8s |
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

See `.claude/context/todos.md` for full roadmap.

## Conventions

**Code & Config:**
- Terraform for VM provisioning (`infra/{olympus,hal9000}/terraform`)
- Static Docker Compose per VM for services (`infra/olympus/services/<name>/`)
- K8s manifests in `kubernetes/`
- No sensitive data in git — `.env` per VM (gitignored), Vault for
  everything else. See `.gitignore` before adding anything under `infra/`

**File Organization:**
- `infra/olympus/terraform/` — Proxmox VM provisioning (vault, authentik,
  postgres, omni, tftp, netboot)
- `infra/hal9000/terraform/` — Talos k8s cluster VM provisioning
- `infra/olympus/services/` — static `docker-compose.yml` per VM service
- `infra/proxmox/` — small proxmoxer helper script (WIP, incomplete)
- `kubernetes/` — k8s manifests for the hal9000 cluster

## When to Update This File

- Architecture changes (node additions, network changes)
- New P0 blockers
- Major decision points
- **NOT:** Day-to-day operational updates (those go in context/)

Keep this file small. Reference detailed docs, don't duplicate.
