# Network Configuration

## IP Addressing (192.168.1.0/24)

| FQDN | IP | Device | Role |
|------|----|----|------|
| udm.bgalhardo.internal | 192.168.1.1 | UDM Pro | Gateway |
| athena.bgalhardo.internal | **192.168.1.196** (Pi4 online 2026-09-08 — MAC `2C:CF:67:64:2C:1D`, DHCP; pin in UniFi) | Pi4 4GB, arm64, 120GB SSD | Runs the Argus stack — logging + metrics + report agent |
| apollo.bgalhardo.internal | 192.168.1.197 (confirmed 2026-08-21 — Proxmox mgmt port 8006 open, ping OK) | Beelink | Proxmox host |
| hades.bgalhardo.internal | 192.168.1.198 | Ryzen PC | Proxmox host + NAS |
| hermes.bgalhardo.internal | 192.168.1.199 | Pi B+ | DNS/LB |
| qdevice | **192.168.1.89** (set up 2026-09-07) | Apollo LXC (Debian) | Corosync qnetd — cluster quorum vote (TCP 5403) |
| manager | **192.168.1.170** (confirmed 2026-08-21) | Apollo VM | SSH/Terraform jump host for Olympus VMs |
| omni.bgalhardo.internal | **192.168.1.171** (confirmed 2026-09-08 — ARP/MAC `BC:24:11:BA:BA:F8`) | Apollo VM | Talos/k8s management |
| vault.bgalhardo.internal | **192.168.1.173** (confirmed 2026-09-08 — ARP/MAC `BC:24:11:08:37:CD`) | Apollo VM | Secrets |
| authentik.bgalhardo.internal | **192.168.1.174** (confirmed 2026-09-08 — ARP/MAC `BC:24:11:67:A4:00`) | Apollo VM | Identity |
| postgres.bgalhardo.internal | **192.168.1.177** (confirmed 2026-08-21) | Apollo VM | Database |
| control-1 (k8s) | **192.168.1.180** (also the Talos CP VIP `:6443`) | Apollo VM | k8s control plane |
| proxmox.bgalhardo.internal | HAProxy → .197 / .198 | Apollo/Hades | Proxmox HA |
| ha.bgalhardo.internal | K8s IP | Apollo | Home Assistant |
| prometheus.bgalhardo.internal | K8s IP | Apollo | Metrics |
| grafana.bgalhardo.internal | K8s IP | Apollo | Dashboards |

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
  `todos.md` P0 "Fix Apollo DNS Record" — the fix is three
  `address=/…/` lines (`.197` / `.198` / `.199`), not a "bad" record.
  Low severity in practice: nothing resolves these by name today (Proxmox
  API is hit by IP; the HA name is `proxmox.bgalhardo.internal`).
- **Certificates:** Vault-managed *.bgalhardo.internal (see Certificate Management below)
- **Auto-renewal:** Not implemented — certs are issued manually via `vault write pki_infra/issue/internal`

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
                        Talos/hal9000 k8s cluster (path
                        pki_cert_manager/sign/internal). Broken
                        2025-12-12 → 2026-08-21 (see K8s auth incident
                        below), now active and issuing again.
```

- **Renewal:** Not automated. Certs are issued by hand via
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
- **Root CA trust:** `bgalhardo.internal`'s root CA is not in any public
  trust store — must be imported manually into each browser/client
  (Firefox: Settings → Certificates → Authorities → Import).
- **Upload gotcha:** Vault only returns the leaf cert as `certificate` —
  most upload UIs (UniFi, Proxmox) need leaf+intermediate concatenated,
  not the `ca_chain` field alone (that's CA-only and will never match the
  private key).

## Proxmox API Access

- **Endpoint:** `https://192.168.1.197:8006/api2/json` (reachable directly
  from a workstation on this LAN — no jump host needed for the API itself,
  unlike SSH to the Olympus VMs)
- **Version confirmed 2026-08-21:** PVE 9.2.3, both nodes (`apollo`,
  `hades`) online
- **Old token (`root@pam!terraform`, in `infra/terraform.tfvars`):**
  rejected with 401 — stale/revoked, not a network issue (confirmed same
  result from this workstation and from `manager`)
- **`claude@pve!claude-readonly` token — working as of 2026-08-25.**
  Secret lives in `.claude/secrets/proxmox.env` (gitignored, not this
  file — see repo root `.gitignore`).
  **History:** originally created with privilege separation enabled
  (`--privsep 1`) and `PVEAuditor` granted directly to the token entity
  — this returned `403 Permission check failed (Sys.Audit)` on
  everything beyond `/version`/`/nodes`, confirmed not a `pveproxy`
  cache issue (restarted `pveproxy`+`pvedaemon`, no change) and not
  fixed by a PVE upgrade (9.2.3 → 9.2.11, retested, still broken).
  Root cause: `pvesh get /access/permissions --userid <id>` resolved
  correctly for `automation@pve!automation` (privsep=0, ACL on the
  **user**) but resolved to `{}` for `claude@pve!claude-readonly`
  (privsep=1, ACL on the **token**), even though `/etc/pve/user.cfg`
  and `pveum acl list` both showed the token's ACL line as syntactically
  correct. This PVE build (through at least 9.2.11) does not appear to
  honor token-scoped (`type: token`) ACL entries at all.
  **Fix:** switched to `--privsep 0` and moved the `PVEAuditor` grant
  from the token to the plain user `claude@pve` — same pattern
  `automation@pve` already used successfully. Token now resolves full
  audit permissions; confirmed working against `/nodes/<node>/status`,
  `/nodes/<node>/disks/list`, `/nodes/<node>/storage`. Practical
  implication: **privilege separation on API tokens should be considered
  non-functional on this cluster** until/unless retested on a future PVE
  version — grant ACLs to the user, not the token, for any new
  read/write token going forward.
- **SSH access to the Proxmox hosts themselves** (not just the Olympus
  VMs) also goes through `manager` (192.168.1.170) as a jump host —
  direct `ssh root@192.168.1.197` from an arbitrary workstation is
  refused (no trusted key). `ssh root@192.168.1.170` then `ssh
  root@192.168.1.197` from there works. Used 2026-08-25 to run `pveum`/
  `pvesh` commands for the token work above.

## Known Access Gotchas

- **Omni's k8s-proxy CA ≠ Kubernetes' internal CA.** A kubeconfig
  downloaded from Omni for the `hal9000` cluster has (at least) 3 cluster
  entries. Only the direct-to-apiserver one (`hal9000`, `192.168.1.180:6443`,
  the Talos control-plane VIP — see `infra/hal9000/talos/control.yml`)
  uses the Talos-internal `O=kubernetes` CA correctly. The two that go
  through Omni's proxy (`omni-hal9000`, `omni-hal9000-bgalhardo`, both
  `https://omni.bgalhardo.internal:8100`) actually present the homelab's
  own PKI leaf cert for `omni.bgalhardo.internal` (see Certificate
  Management below) — kubectl needs `certificate-authority` set to the
  homelab root CA for those two, not the k8s-internal one, or you get
  `x509: certificate signed by unknown authority`.
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
  `infra/olympus/services/vault/bootstrap-k8s-auth.sh`, which now also
  codifies the roles/policies/CA-refresh that used to live only in Vault
  itself — re-run it if this recurs. Also fixed in passing: two
  `VaultStaticSecret`s (`cloudflare-ddns`, `cloudflare-letsencrypt`) were
  colliding on the same destination Secret name; the letsencrypt one now
  targets `cloudflare-api-token-letsencrypt`.
- **Getting `kubectl` working against `hal9000` via Omni, end to end**
  (confirmed working 2026-08-21):
  1. Log into Omni UI (`https://omni.bgalhardo.internal`) via SAML SSO,
     download kubeconfig for the `hal9000` cluster
  2. That download uses an `exec`-based OIDC plugin (`kubectl oidc-login`,
     from [int128/kubelogin](https://github.com/int128/kubelogin)) — not
     a static token. Install it as `kubectl-oidc_login` somewhere on
     `PATH` (e.g. `~/.local/bin`) — it's not a stock kubectl subcommand
  3. The download also has **no `certificate-authority-data` at all** —
     add it: `kubectl config set-cluster omni-hal9000
     --certificate-authority=<root-ca.pem> --embed-certs=true`
  4. The OIDC plugin makes its **own separate HTTPS call** (to
     `/oidc/.well-known/openid-configuration`) that does *not* inherit
     the cluster's CA data — it needs its own `--certificate-authority=
     <path>` flag added to the `exec.args` list in the kubeconfig
     directly, pointing at a durable copy of the root CA (not a
     temp/session path)
  5. The resulting `kubectl` command triggers a real interactive browser
     OAuth flow (redirects to `http://localhost:8000/?code=...`, caught
     by kubelogin's local callback listener) — must be run directly in
     an interactive terminal by a human, not backgrounded or run with a
     tight timeout that kills the listener before the browser redirect
     completes

## Connectivity Summary

- **Gateway:** UDM Pro (dual function: gateway + switch)
- **Uplink:** UDM port 9 to ISP (bridge mode)
- **Cluster nodes:** Direct to UDM (no bonding/LAGG)
- **Utility node:** Hermes independent (can survive cluster outage)
- **Storage access:** Hades NFS over same network segment
