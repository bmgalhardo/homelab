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
| home.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `home` | Home Assistant (LAN/VPN) |
| mosquitto (MQTT :1883) | **192.168.1.202** (MetalLB, pinned by annotation) | k8s `home` | Broker — Shellys point here by IP |
| ibgateway.bgalhardo.internal | **192.168.1.203** (MetalLB, pinned by annotation) `:4002` | k8s `trading` | IB Gateway, paper API |
| git-ssh.bgalhardo.internal | **192.168.1.204** (MetalLB, pinned by annotation) `:22` → pod `:2222` | k8s `forgejo` | Forgejo built-in SSH (git clone/push) |
| openwebui.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `ai` | Open WebUI |
| litellm.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `ai` | LiteLLM proxy |
| projects.bgalhardo.internal | Gateway `internal` → 192.168.1.200 | k8s `system` | Project builds, docs, review mocks |
| prometheus / grafana | athena `:9090` / `:3000` | athena | Metrics, dashboards |

## DNS (dnsmasq on Hermes) — resolution only; **DHCP is the UDM Pro**

- **Domain:** bgalhardo.internal
- **Resolver:** Hermes (192.168.1.199:53), single upstream `1.1.1.1`,
  `no-resolv`. dnsmasq DHCP is disabled — fixed-IP reservations are set on
  the **UDM Pro** by MAC.
- **Wildcards + overrides:** dnsmasq has catch-alls
  `address=/.bgalhardo.internal/192.168.1.200` and
  `address=/.bgalhardo.com/192.168.1.201` (→ k8s ingress). Per-host
  `address=/host.bgalhardo.internal/IP` lines override them (dnsmasq
  longest-match). Explicit records exist for authentik, proxmox (→ .199
  HAProxy), unifi, omni, vault, athena, postgres, truenas.
- **`apollo` / `hades` / `hermes` have no explicit record** and resolve to
  the `.200` wildcard. Reach them by IP (`.197` / `.198` / `.199`); the
  Proxmox API name is `proxmox.bgalhardo.internal`.

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
                        pki_cert_manager/sign/internal).
```

- **Renewal:** k8s certs renew via cert-manager; athena's leaf via its
  Vault Agent. Every other `pki_infra` leaf is issued by hand via
  `vault write pki_infra/issue/internal common_name=<host>.bgalhardo.internal`
  and manually copied into each VM's `./certs/` (docker-compose volume,
  see `infra/olympus/services/<name>/`).
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
  Secret lives in Vault `kv/agents/proxmox` (read with
  `infra/daedalus/agent-secret.sh env proxmox`).
  **Token-scoped ACLs don't work on this cluster** (privsep=1 tokens resolved
  to no permissions through PVE 9.2.11): use `--privsep 0` and grant the role
  to the user, as `automation@pve` and `claude@pve` do.
- **`daedalus@pve!power` token** — start/stop VMs for daedalus. Role
  `VMPower` (`VM.PowerMgmt VM.Audit Sys.Audit Mapping.Use`) on the user,
  privsep 0, ACLs on `/vms`, `/nodes`, `/mapping/pci/nvidia_750ti`. Secret
  in Vault `kv/agents/proxmox-power`. No host power (`Sys.PowerMgmt`) —
  hades is woken by WoL from daedalus, never shut down by it.
- **SSH access to the Proxmox hosts themselves** — no jump host since
  2026-09-26 (`manager` deleted 2026-09-14, hermes no longer holds keys).
  `ssh root@192.168.1.197` works only from a workstation whose key is
  authorized there; the user keeps the keys off-cluster.

## Manual renewals

- **Omni service-account JWTs** last a year. A fresh kubeconfig downloaded
  from the Omni UI carries a new one.
- **Vault kubernetes auth:** `auth/kubernetes/config` must keep
  `token_reviewer_jwt` (Vault runs off-cluster). Re-run
  `infra/vault/k8s-auth-bootstrap.sh` to restore the roles, policies and CA.

## Connectivity Summary

- **Gateway:** UDM Pro (dual function: gateway + switch)
- **Uplink:** UDM port 9 (`eth8`, WAN1) to ISP (bridge mode)
- **WAN drops are known and expected:** a toddler switches the ISP router
  off, so `eth8: Link is Down` recurs. Internal DNS (Hermes, `*.bgalhardo.internal`)
  keeps working; only lookups and NTP that need the internet fail. Treat these as
  side effects of the drop, not separate incidents: Talos `error serving dns
  request` / `time query error`, CoreDNS SERVFAIL for external names, Flux
  `lookup github.com`, `probe_dns_upstream` (cloudflare.com), UDM linkcheck
  and AP `dns_timeout`. Report it as one info line, "WAN down N× (times)". It is
  only a warning if `probe_dns` (the internal-name probe) fails during the drop
  too, because that means Hermes itself is broken.
- **Cluster nodes:** Direct to UDM (no bonding/LAGG)
- **Utility node:** Hermes independent (can survive cluster outage)
- **Storage access:** virtiofs from Hades into `elysium-hades` (no NFS)
