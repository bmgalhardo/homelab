# Network Configuration

## IP Addressing (192.168.1.0/24)

| FQDN | IP | Device | Role |
|------|----|----|------|
| udm.bgalhardo.internal | 192.168.1.1 | UDM Pro | Gateway |
| athena.bgalhardo.internal | **192.168.1.196** (Pi4 online 2026-09-08 — MAC `2C:CF:67:64:2C:1D`, DHCP; pin in UniFi) | Pi4 4GB, arm64, 120GB SSD | Monitoring node — logging + metrics, runs the argus agent |
| apollo.bgalhardo.internal | 192.168.1.197 (confirmed 2026-08-21 — Proxmox mgmt port 8006 open, ping OK) | Beelink | Proxmox host |
| hades.bgalhardo.internal | 192.168.1.198 (MAC `f0:2f:74:30:76:71`, enp10s0) | Ryzen PC | Proxmox host + NAS |
| hermes.bgalhardo.internal | 192.168.1.199 | Pi B+ | DNS/LB |
| qdevice | **192.168.1.89** (set up 2026-09-07) | Apollo LXC (Debian) | Corosync qnetd — cluster quorum vote (TCP 5403) |
| cerberus | **192.168.1.175** (LXC 105, on/off by hand) | Apollo LXC (Debian) | Protect kiosk on Apollo HDMI |
| daedalus | **192.168.1.170** | Apollo VM 101 | Remote agents (Claude Code) |
| hephaestus | **192.168.1.176** (LXC 106, 2026-10-07) | Hades LXC | Headless Blender worker |
| omni.bgalhardo.internal | **192.168.1.171** (confirmed 2026-09-08 — ARP/MAC `BC:24:11:BA:BA:F8`) | Apollo VM | Talos/k8s management |
| vault.bgalhardo.internal | **192.168.1.173** (confirmed 2026-09-08 — ARP/MAC `BC:24:11:08:37:CD`) | Apollo VM | Secrets |
| authentik.bgalhardo.internal | **192.168.1.174** (confirmed 2026-09-08 — ARP/MAC `BC:24:11:67:A4:00`) | Apollo VM | Identity |
| postgres.bgalhardo.internal | **192.168.1.177** (confirmed 2026-08-21) | Apollo VM | Database |
| control-1 (k8s) | **192.168.1.180** (also the Talos CP VIP `:6443`) | Apollo VM | k8s control plane |
| proxmox.bgalhardo.internal | HAProxy → .197 / .198 | Apollo/Hades | Proxmox HA |
| home.bgalhardo.com | Gateway `external` → 192.168.1.201 | k8s `home` | Home Assistant |
| mosquitto (MQTT :1883) | **192.168.1.202** (MetalLB, pinned by annotation) | k8s `home` | Broker — Shellys point here by IP |
| openwebui.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `ai` | Open WebUI |
| litellm.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `ai` | LiteLLM proxy |
| games.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `system` | Game builds, docs, review boards |
| prometheus / grafana | athena `:9090` / `:3000` | athena | Metrics, dashboards |

## DNS (dnsmasq on Hermes) — resolution only; **DHCP is the UDM Pro**

- **Domain:** bgalhardo.internal
- **Resolver:** Hermes (192.168.1.199:53), single upstream `1.1.1.1`,
  `no-resolv`. dnsmasq DHCP is disabled — fixed-IP reservations are set on
  the **UDM Pro** by MAC.
- **Backup DNS:** HAProxy fallback (not redundant yet). **Future:** Pi4 as
  backup dnsmasq.
- **Wildcards + overrides:** dnsmasq has catch-alls
  `address=/.bgalhardo.internal/192.168.1.200` and
  `address=/.bgalhardo.com/192.168.1.201` (→ k8s ingress). Per-host
  `address=/host.bgalhardo.internal/IP` lines override them (dnsmasq
  longest-match). Explicit records exist for authentik, proxmox (→ .199
  HAProxy), unifi, omni, vault, athena, postgres, truenas.
- ⚠️ **`apollo` / `hades` / `hermes` have no explicit record** → they hit
  the `.200` wildcard (k8s ingress), not the real host. This is the
  `plans/todos.md` P0 "Fix Apollo DNS Record" — the fix is three
  `address=/…/` lines (`.197` / `.198` / `.199`), not a "bad" record.
  Low severity in practice: nothing resolves these by name today (Proxmox
  API is hit by IP; the HA name is `proxmox.bgalhardo.internal`).

## Load Balancer (HAProxy on Hermes)

### Backend: proxmox
- **Targets:** Apollo (192.168.1.197), Hades (192.168.1.198)
- **DNS Entry:** proxmox.bgalhardo.internal
- **Purpose:** HA Proxmox access (failover to healthy node)
- **Protocol:** HTTP/HTTPS

### Backend: postgres
- **Target:** postgres-vm on Apollo
- **DNS Entry:** postgres.bgalhardo.internal
- **Purpose:** HA database access
- **Protocol:** TCP 5432

## VLANs (on UDM)

- **VLAN 1 (default):** Primary network — all homelab services
- **VLAN 2 (guest):** Guest wifi (not used for homelab)
- **VLAN 3 (iot):** IoT devices (not actively configured)

## Topology

```
ISP (MEO Thomson)
  ↓
  UDM Pro (192.168.1.1) - gateway + switch
  ├─→ Apollo (192.168.1.197)
  ├─→ Hades (192.168.1.198)
  ├─→ Hermes (192.168.1.199)
  └─→ POE Switch
      ├─→ Unifi AP U6+
      ├─→ Unifi cameras
      └─→ Household ethernet outlets
```

## Certificate Management

### PKI Hierarchy (Vault)

```
pki_root (self-signed Root CA, 2025-07-01 → 2035-06-29)
  ├── pki_infra   — Intermediate CA "[infra]" (→ 2030-06-30)
  │                 Leaf certs for VM/non-k8s services (Olympus tier,
  │                 deployed via infra/olympus/services/, see deployment.md)
  │                 Role: "internal" — allowed_domains=bgalhardo.internal,
  │                 allows subdomains + wildcards, max_ttl=360d
  │
  └── pki_cert_manager — Second intermediate, separate chain
                        Used by cert-manager's `vault` Issuer inside the
                        elysium k8s cluster (path
                        pki_cert_manager/sign/internal). Broken
                        2025-12-12 → 2026-08-21 (see K8s auth incident
                        below).
```

- **Renewal:** k8s certs renew via cert-manager; athena's leaf via its
  Vault Agent. Every other `pki_infra` leaf is issued by hand via
  `vault write pki_infra/issue/internal common_name=<host>.bgalhardo.internal`
  and manually copied into each VM's `./certs/` (docker-compose volume,
  see `infra/olympus/services/<name>/`).
  This lack of automation is what let every `pki_infra` leaf cert expire
  silently in 2026 — building real renewal automation is still open.
- **Leaf cert status (as of 2026-08-21):** reissued 2026-08-20, valid to
  2027-08-15 (360d, the role's current max_ttl).
  | Host | Status |
  |------|--------|
  | vault, authentik, proxmox, unifi, omni | ✅ Live, full chain verified against root CA |
  | truenas | Cert issued, not yet installed — host is offline (power-managed) |
  | netboot | Retired — cert revoked in `pki_infra`, service no longer used |
- **Root CA file:** committed at `infra/ca/root-ca.crt` and distributed from
  there, not fetched from Vault — the CA is what proves "this is really
  Vault", so fetching it over an unverified connection would let a MITM hand
  over its own CA and own that machine's trust until 2035. Static for a
  decade, so it belongs in the provisioning artifact.
- **Root CA trust:** `bgalhardo.internal`'s root CA is not in any public
  trust store — must be imported manually into each browser/client
  (Firefox: Settings → Certificates → Authorities → Import).
- **Upload gotcha:** Vault only returns the leaf cert as `certificate` —
  most upload UIs (UniFi, Proxmox) need leaf+intermediate concatenated,
  not the `ca_chain` field alone (that's CA-only and will never match the
  private key).

## Proxmox API Access

- **Endpoint:** `https://proxmox.bgalhardo.internal/api2/json` — port 443 on
  hermes HAProxy (SNI passthrough → apollo:8006, hades as backup). The node
  cert only names `proxmox.bgalhardo.internal`, so `https://192.168.1.197:8006`
  fails TLS verification.
- **Version confirmed 2026-08-21:** PVE 9.2.3, both nodes (`apollo`,
  `hades`) online
- **`claude@pve!claude-readonly` token — working as of 2026-08-25.**
  Secret lives in `.agents/secrets/proxmox.env` (gitignored, not this
  file — see repo root `.gitignore`).
  **Token-scoped ACLs don't work on this cluster** (privsep=1 tokens resolved
  to no permissions through PVE 9.2.11): use `--privsep 0` and grant the role
  to the user, as `automation@pve` and `claude@pve` do.
- **`daedalus@pve!power` token** — start/stop VMs for daedalus. Role
  `VMPower` (`VM.PowerMgmt VM.Audit Sys.Audit Mapping.Use`) on the user,
  privsep 0, ACLs on `/vms`, `/nodes`, `/mapping/pci/nvidia_750ti`. Secret
  in `.agents/secrets/proxmox-power.env`. No host power (`Sys.PowerMgmt`) —
  hades is woken by WoL from daedalus, never shut down by it.
- **SSH access to the Proxmox hosts themselves** — no jump host since
  2026-09-26 (`manager` deleted 2026-09-14, hermes no longer holds keys).
  `ssh root@192.168.1.197` works only from a workstation whose key is
  authorized there; the user keeps the keys off-cluster.

## Known Access Gotchas

- **Authentik's SAML *signing* cert is separate from its TLS cert**, and
  just as unrenewed. Found expired 2026-08-21 (`CN=authentik self-signed`,
  expired 2026-05-25) — this breaks SSO into Omni specifically (SAML
  assertion signature validation), independent of any TLS/PKI work. Fix
  is in Authentik's own admin UI: System → Certificates → regenerate, then
  set it as the Signing Certificate on the affected SAML Provider.
  **After regenerating, the relying party (Omni) must be restarted** —
  it caches the IdP's SAML metadata (fetched from
  `.../application/saml/omni/metadata/`) and won't pick up the new
  signing cert until it re-fetches. This will recur next time this cert
  expires (~2027-08) unless something automates it.
- **Omni's own service-account JWTs also expire silently and aren't
  renewed automatically** — found one issued 2025-07-06, expired
  2026-07-06 (46 days before being noticed). A fresh kubeconfig
  (downloaded from the Omni UI after logging in) gets a new one; there's
  no other renewal path currently.
- **Vault kubernetes-auth outage, 2025-12-12 → 2026-08-21 (fixed):**
  `auth/kubernetes/config` was missing `token_reviewer_jwt` (mandatory
  since Vault runs off-cluster on Apollo, not as a pod) — every
  kubernetes-auth login 403'd, breaking cert-manager's `vault` Issuer and
  every VaultSecretsOperator secret. Fixed via
  `infra/vault/k8s-auth-bootstrap.sh`, which now also
  codifies the roles/policies/CA-refresh that used to live only in Vault
  itself — re-run it if this recurs. Also fixed in passing: two
  `VaultStaticSecret`s (`cloudflare-ddns`, `cloudflare-letsencrypt`) were
  colliding on the same destination Secret name; the letsencrypt one now
  targets `cloudflare-api-token-letsencrypt`.

## Connectivity Summary

- **Gateway:** UDM Pro (dual function: gateway + switch)
- **Uplink:** UDM port 9 (`eth8`, WAN1) to ISP (bridge mode)
- **Cluster nodes:** Direct to UDM (no bonding/LAGG)
- **Utility node:** Hermes independent (can survive cluster outage)
- **Storage access:** virtiofs from Hades into `elysium-hades` (no NFS)
