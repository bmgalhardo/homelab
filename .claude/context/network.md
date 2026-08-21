# Network Configuration

## IP Addressing (192.168.1.0/24)

| FQDN | IP | Device | Role |
|------|----|----|------|
| udm.bgalhardo.internal | 192.168.1.1 | UDM Pro | Gateway |
| apollo.bgalhardo.internal | 192.168.1.197 (confirmed 2026-08-21 — Proxmox mgmt port 8006 open, ping OK) | Beelink | Proxmox host |
| hades.bgalhardo.internal | 192.168.1.198 | Ryzen PC | Proxmox host + NAS |
| hermes.bgalhardo.internal | 192.168.1.199 | Pi B+ | DNS/LB |
| vault.bgalhardo.internal | 192.168.1.197 (unverified — accessed via DNS, not by IP, this session) | Apollo VM | Secrets |
| authentik.bgalhardo.internal | 192.168.1.197 (unverified — same) | Apollo VM | Identity |
| postgres.bgalhardo.internal | **192.168.1.177** (confirmed 2026-08-21) | Apollo VM | Database |
| tftp | **192.168.1.172** (confirmed 2026-08-21) | Apollo VM | PXE/TFTP |
| manager | **192.168.1.170** (confirmed 2026-08-21) | Apollo VM | SSH/Terraform jump host for Olympus VMs — undocumented until now |
| proxmox.bgalhardo.internal | HAProxy | Apollo/Hades | Proxmox HA |
| ha.bgalhardo.internal | K8s IP | Apollo | Home Assistant |
| prometheus.bgalhardo.internal | K8s IP | Apollo | Metrics |
| grafana.bgalhardo.internal | K8s IP | Apollo | Dashboards |

## DNS (dnsmasq on Hermes)

- **Domain:** bgalhardo.internal
- **Resolver:** Hermes (192.168.1.199:53)
- **Backup DNS:** HAProxy fallback (not redundant yet)
- **Future:** Pi4 as backup dnsmasq
- ⚠️ **Known bad record (2026-08-21):** `apollo.bgalhardo.internal` resolves
  to `192.168.1.200` via Hermes DNS — wrong. The real, reachable Apollo
  Proxmox host is `192.168.1.197` (confirmed: port 8006 open, responds to
  ping; `.200` doesn't respond to either). Not yet fixed on Hermes.
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
- **New read-only token created 2026-08-21:** `claude@pve!claude-readonly`,
  `PVEAuditor` role granted at path `/` with Propagate — confirmed present
  in Datacenter → Permissions via screenshot, yet still returns
  `403 Permission check failed (Sys.Audit)` on every endpoint beyond the
  unauthenticated `/version` and the always-visible `/nodes` list.
  **Status: unresolved as of 2026-08-21.** A 20-minute background poll for
  the permission to become effective (in case of `pveproxy` cache) timed
  out. Next step, not yet tried: restart `pveproxy` on Apollo for an
  immediate reload, or investigate further — don't assume it's just cache
  lag anymore given the timeout.

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
