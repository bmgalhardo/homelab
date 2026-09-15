# Todos: Priorities & Blockers

## P0: Critical (Blocking)

### local-path Never Worked — Talos Disk Selector (found 2026-09-15)
- **Status:** root cause found, fix committed to
  `infra/elysium/omni/patches/local-path.yaml`. **Needs
  `omnictl cluster template sync` + a node reboot to take effect.**
- **Symptom:** every `local-path` PVC Pending forever. Zero local-path PVs
  have ever existed on elysium.
  - `ai/ollama-models` — Pending since 2026-09-13T22:58 (~38h before it was
    noticed)
  - `obsidian/obsidian-config` — Pending since 2026-09-15T12:55
  - `openwebui` in CrashLoopBackOff, **423 restarts** — a downstream effect
    of ollama never starting, not an openwebui bug
- **Root cause:** the Talos user volume failed at boot on both workers:
  ```
  talosctl -n talos-562-ij1 get volumestatus u-local-path -o yaml
    spec.phase: failed
    spec.errorMessage: no disks matched selector for volume
  ```
  The selector was `'!system_disk && disk.transport == "scsi"'`, but these
  VMs use the `virtio-scsi-single` controller — the disks present as
  `/dev/sdX` yet Talos reports transport **virtio**:
  ```
  talosctl -n talos-562-ij1 get disks
    sda  43 GB  virtio  QEMU HARDDISK   <- system disk
    sdb  64 GB  virtio  QEMU HARDDISK   <- intended local-path disk (60G)
  ```
  So the selector matched nothing. The hardware was never the problem —
  `elysium-apollo scsi1: 60G` and `elysium-hades scsi1: 100G` are both
  attached exactly as `configs.auto.tfvars.json` declares.
- **Fix applied in repo:** drop the transport predicate, keep
  `match: '!system_disk'` + `minSize: 50GB` (already unambiguous — the system
  disk is 43 GB, under minSize; loop/DVD devices are far smaller). Comment
  left in the patch so it is not re-added.
- **Remaining:** `omnictl cluster template sync`, then reboot the workers —
  the VolumeStatus was `version: 1`, evaluated once at boot and never
  re-evaluated, so a sync alone may not retry it. Then `ollama`, `openwebui`
  and `obsidian` should all come up with no manifest changes.
- **Why nobody noticed for 38h — this is the lesson:** a Pending PVC emits
  no logs, no events of its own, and no failed reconcile. **Flux reported the
  Kustomization healthy, correctly** — the resources were applied as
  declared. Only the Talos layer knew, in one field. Captured as a worked
  example in `argus.md` and added there as a fact probe.
- **Blocks:** `.claude/secrets/omni.env` (Omni service account) is **missing**,
  so headless `talosctl`/`omnictl` do not work — it falls back to interactive
  browser auth. Restore it; the Argus Talos probe depends on it too.


### ⛔ There Is Effectively One Copy Of Everything (found 2026-09-15)
- **Task:** ZFS snapshots on `odin`, then replication to TrueNAS. Nothing
  else in the backup plan matters until this exists.
- **Evidence gathered 2026-09-15 on hades — this is measured, not assumed:**
  ```
  zfs list -t snapshot   ->  odin/photos@backup-2025-12-03T16:48:20   (ONE, from December)
  zfs list -t bookmark   ->  none
  sanoid/syncoid         ->  not installed
  zfs cron               ->  trim + scrub only. no replication.
  ```
- **What that means:** `zfs send` sends a *snapshot*, and incrementals leave
  bookmarks or holds. There are none. So:
  - The only dataset that could ever have been ZFS-replicated is
    `odin/photos`, as of **2025-12-03** (~9 months stale).
  - **`odin/backups` (40.2G) has never been snapshotted, so it has never been
    ZFS-replicated at all.** That dataset holds `phd_thesis`, `CV`,
    `design_jobs`, `fatima`, `LIP`, `arquivo`, `print-n-play`, `work_curso`
    *plus* the home-assistant / plex / sabnzbd / mongo app backups.
  - If TrueNAS holds copies they came from rsync or a one-off, not ongoing
    replication.
- **The mirror is not a backup.** RAID-1 on `odin` protects against a disk
  dying. It does nothing against deletion, corruption, ransomware or a
  pool-level mistake. Right now that is the only protection in place.
- **Order of work:**
  1. `sanoid` on `odin/{photos,backups}` — snapshots + retention. ~30 min,
     covers everything already on hades including the personal archives.
  2. Replication to TrueNAS (`syncoid`, or TrueNAS-side replication tasks).
     TrueNAS is power-managed and was offline 2026-09-15 — the schedule has
     to tolerate the target being asleep.
  3. Only then the k8s backup plumbing below. Copies with no snapshot
     history to land in are not worth building first.
- **Decided 2026-09-15: keep TrueNAS, do NOT rebuild it as Proxmox.** A
  backup target should have *uncorrelated* failure modes — a ZFS bug, bad
  kernel update or operator error that kills Proxmox-on-hades would hit an
  identical stack on the backup box simultaneously. That is the "2 different
  media/formats" leg of 3-2-1. TrueNAS also ships snapshot scheduling,
  replication, retention, SMART monitoring and alerting in the UI, which is
  exactly what is missing. Both are OpenZFS so `zfs send`/`recv` interop is a
  non-issue. **Only reason to revisit:** wanting the backup box to double as
  a warm standby that can boot restored VMs (changes RTO materially).

### k8s local-path Is Volatile And Unbacked (found 2026-09-15)
- **Task:** backup plumbing for k8s state. Blocked on the P0 above.
- **Model:** treat `local-path` as **volatile**. Manifests come back from git
  via Flux; only *data* needs restoring. Node dies -> rebuild + restore.
- **Current exposure is small:** immich photos/cache are on virtiofs (hades),
  immich DB is on the postgres VM (has `pg_backup`), and redis/pgadmin/
  homepage/cloudflare-ddns are stateless. The only live local-path volume is
  ollama models, which are regenerable. **`obsidian` (deployed 2026-09-15)
  is the first genuinely irreplaceable local-path volume.**
- **Grows when `_parked/` is unparked:** plex (20Gi), sonarr, radarr,
  sabnzbd, overseerr and home-assistant all put `/config` on local-path.
- **Two different designs, because of node locality:**
  - **Apollo-pinned apps (obsidian, home-assistant)** — virtiofs volumes
    mount on `elysium-hades` ONLY, and a local-path PVC can only be mounted
    from the node holding it. **No single pod can mount both**, so an
    in-cluster Apollo->hades file copy is impossible. Backup must leave the
    node over the network: git push (ideal for markdown — adds per-change
    history) or restic/rsync. A bare repo on hades works as the remote and
    lands on ZFS; GitHub adds the off-site leg. GitHub free has unlimited
    private repos but ~1GB/repo soft limit and a hard 100MB per-file cap, so
    it suits text vaults, not attachment-heavy ones.
  - **hades-pinned apps (plex, *arr)** — their local-path lives on the hades
    node, where virtiofs also is, so one pod can mount both (RWO means one
    *node*, not one pod). Plain CronJob copy, no network hop.
- **SQLite is the trap.** Plex, sonarr, radarr, overseerr are all SQLite in
  WAL mode (3 files: `.db`, `.db-wal`, `.db-shm`). Copying the live file can
  restore corrupt. **Back up the app's own backup output, not its live data
  dir** — Plex has Settings -> Scheduled Tasks -> Backup Database; the *arr
  apps have Settings -> General -> Backups. A ZFS snapshot is atomic and
  therefore crash-consistent (equivalent to power loss, which SQLite normally
  survives) — acceptable as a floor, not as the plan.
- **Do NOT virtiofs-mount `/odin/backups` into the cluster.** It mixes app
  backups with personal archives (thesis, CV, design work), and Plex/sabnzbd
  ingest untrusted content. Create a dedicated dataset instead:
  `zfs create odin/k8s-backups && zfs set quota=200G odin/k8s-backups`, then
  a virtiofs mount + PV for that alone.
- **Never mount the backup target into the app pod** — only into the backup
  job. An unavailable volume would otherwise hang the app in
  `ContainerCreating`.
- **Alert on freshness, not job success.** hades and TrueNAS are both
  power-managed, so a job failing because the target is asleep is expected,
  not an incident. The backup job should exit 0 with a log line when the
  target is unreachable; Argus then alerts on *staleness* of the newest
  backup. This is already a planned Argus fact probe (`argus.md`).


### Nothing in This Stack Auto-Renews ⛔
- **Task:** Recognize this as a systemic pattern, not one-off bugs, and
  prioritize renewal automation accordingly
- **Why:** As of 2026-08-21, several independent credentials/certs were
  found expired or misconfigured across totally different systems, all
  with the same root cause (manual issuance, no automation, no expiry
  alerts):
  1. All 9 `pki_infra` leaf certs (the original P0 — fixed 2026-08-20/21)
  2. Omni's own service-account JWT — issued 2025-07-06, expired
     2026-07-06, unnoticed for 46 days (found 2026-08-21)
  3. Authentik's self-signed SAML signing cert — expired 2026-05-25,
     broke SSO into Omni (found + fixed 2026-08-21, but required
     restarting Omni afterward since it caches IdP metadata — will
     recur ~2027-08 unless automated)
- **Status:** Not started — no automation exists for any of these yet
- **Benefit:** Prevents the next 3-month silent outage, whatever it turns
  out to be

### Fix Apollo DNS Record  (downgraded 2026-09-08 — not a P0)
- **Task:** Add explicit dnsmasq records for `apollo` / `hades` / `hermes`
  (`.197` / `.198` / `.199`). They currently have none, so they fall
  through the `address=/.bgalhardo.internal/192.168.1.200` wildcard to the
  k8s ingress.
- **Why:** Found 2026-08-21 reaching the Proxmox API by hostname. Refined
  2026-09-08: it's a *missing* record + a catch-all wildcard, not a bad
  record. **Low severity** — nothing resolves these names today (Proxmox
  API is hit by IP; the HA name is `proxmox.bgalhardo.internal` → .199).
  Worth doing so a mistyped hostname fails clean instead of hitting the
  wrong box.
- **Effort:** Trivial (three `address=/…/` lines on Hermes).
- **Status:** Not started.

### Corosync on Pi Burden ✅ (done 2026-09-07)
- **Task:** Migrate corosync-qdevice to Apollo LXC
- **Status:** Done. Pi (Hermes) re-flashed to Alpine, running dnsmasq +
  HAProxy. New `qdevice` LXC on Apollo (192.168.1.89, Debian) runs
  corosync-qnetd; `pvecm qdevice setup 192.168.1.89` completed. See
  services.md for setup gotchas and the Apollo co-location caveat.
- **Remaining:** confirm `pct set <ctid> --onboot 1` on the LXC; verify
  `pvecm status` shows `Total votes: 3`; test HAProxy failover on Alpine.

## P1: High (This Month)

### 3-2-1 Backup Strategy
- **Task:** Implement 3-copy backup resilience
- **Why:** Currently no automated *offsite* backup; manual process fragile
- **Effort:** 12 hours (4 phases)
- **Blocker:** Backup PC specs, power strategy decision
- **Status:** Planning — Phase 1 partially confirmed 2026-08-21:
  - **Postgres:** `infra/olympus/services/postgres/backup.sh` runs inside the
    `pg_backup` sidecar (in the compose file, confirmed live), does
    daily/weekly/monthly `pg_dumpall` with real retention (7d/28d/365d)
    — but only writes to local disk on the postgres VM
    (`/backups/{daily,weekly,monthly}`). Nothing ships these off-box.
  - **Vault:** No backup mechanism exists at all — worse than Postgres.
    Vault's compose file (`infra/olympus/services/vault/`) has no backup sidecar,
    no snapshot script, nothing. This is the most critical service in
    the homelab with zero backup coverage.
- **Phases:**
  - Phase 1 (2h): Document current DB scripts, retention — postgres done,
    **add a Vault raft snapshot mechanism (`vault operator raft snapshot`)
    — doesn't exist yet, not just undocumented**
  - Phase 2 (4h): Setup rsync/shipping of `backup.sh` output (postgres)
    and new Vault snapshots to backup PC
  - Phase 3 (3h): Enable ZFS snapshots, test restore
  - Phase 4 (3h): Setup monthly external drive sync
- **Benefit:** Resilience against data loss; meets 3-2-1 standard

### Argus: Centralized Logging + Daily Report Agent
- **Task:** Loki + Prometheus + Grafana on the `athena` node (Pi4, off the
  cluster), then an agent that reads 24h of logs + deterministic fact
  probes at 04:00, reports to Telegram, writes eventful things to
  `logbook/YYYY-MM.md`
- **Why:** Every silent outage in this file (expired certs, expired Omni JWT,
  missing `token_reviewer_jwt`) went unnoticed for months. Nothing watches.
- **Status (2026-09-08):** `athena` node online (`.196`), stack written
  (`infra/athena/`), not yet deployed. Vault Agent sidecar built here as
  the reusable pattern. Phase 1 = deploy + verify.
- **Full design, decisions and phase checklist:** `.claude/context/argus.md`
- **Benefit:** Directly addresses the "nothing in this stack auto-renews"
  P0 above — it can't fix renewals, but it stops them failing silently

### Full VM Provisioning: Terraform + Bundled Compose ⚠️
- **Task:** Two parts.
  1. **Fix or formally retire the Olympus Terraform.** State has drifted
     ~9 months out of sync with the live cluster and cannot be safely
     `apply`d as-is.
  2. **Standardize the VM contract:** Terraform provisions the VM, then a
     single `docker-compose.yml` per VM bundles *everything that VM needs*
     — the service itself + Vault Agent (secret injection) + backup script
     + log shipping (Alloy, or syslog forward for Argus). Create the VM,
     drop in the compose file, done. The 200-series `postgres` VM (with
     its `pg_backup` sidecar) is the closest existing pattern — extend it
     to cover secrets and logging too.
- **Why (drift evidence, gathered 2026-09-08):**
  - No `terraform` binary on the workstation; no remote backend — state is
    one gitignored file, last written **2025-12-12** (hal9000 state:
    2025-07-06)
  - `infra/terraform.tfvars` still uses `root@pam!terraform` → 401/revoked
    (network.md). Needs a **user-scoped** write token — token-scoped ACLs
    are non-functional on this PVE build (network.md)
  - `vault` / `authentik` / `omni` were rebuilt by hand at vmid
    **107 / 103 / 100**; state still says 204 / 205 / 206
  - `netboot-webserver` (vmid 203) retired but still in state
  - `tftp-server` (vmid 202) removed 2026-09-08 from tfvars + repo; still
    in state (and the VM itself, until deleted)
  - hal9000 `worker-1` is **8192 MB** live, 4096 in code + state
- **Options:**
  - A: **Reconcile** — install TF, mint a user-scoped write token, update
    `terraform.tfvars`, `state rm` + re-import the 4 drifted resources,
    wrestle `plan` to zero-diff on the 3 hand-built VMs, then it's usable
  - B: **Retire** — accept deployment.md's "static per VM" reality, delete
    `infra/olympus/terraform/`, document the Olympus VMs as hand-created,
    keep only `infra/hal9000/terraform/`
- **Connects to:** every future Olympus VM; and the hal9000 rebuild (P2) —
  do the `worker-1` resize there. (Argus ended up on a bare Pi4, not a VM,
  so it no longer depends on this.)
- **Status:** Not started. Documented 2026-09-08. User chose option A
  (reconcile) initially; revisit given the full scope above.

### Backup PC Power Strategy Decision ⚠️
- **Task:** Choose backup PC operation mode
- **Options:**
  - A: Always-on 24/7 (~50W, simplest)
  - B: Wake-on-LAN 2-3x daily (~20W, medium complexity)
  - C: Replace with N100 NAS (~5W, $400 investment)
- **Trade-off:** Power cost vs automation vs capital investment
- **Effort:** 0 (decision only)
- **Status:** Pending decision
- **Impact:** Drives backup automation approach

## P2: Medium (Next Month)

### Trivial cipassword on VM Cloud-Init
- **Task:** `infra/olympus/terraform/main.tf` sets `cipassword = "root"`
  via cloud-init on every VM — password auth enabled with a trivial
  password, on top of SSH keys. Should be removed or set to something
  Vault-managed.
- **Status:** Not started. Private LAN only, so not urgent.

### K8s Rebuild: hal9000 → elysium (Flux + infra DONE 2026-09-14)
- **Status 2026-09-14:** cluster up, Flux bootstrapped, all three tiers green.
  MetalLB/NGF/cert-manager/VSO installed; both Gateways programmed with
  **pinned** IPs (internal `.200`, external `.201`); certs issuing from both
  the Vault CA and Let's Encrypt; VSO reading `kv/infra/*` + `kv/apps/*`.
  `system` + `immich` + `ai` deployed. Old hal9000 VMs still **stopped**, not
  destroyed.
- **Access:** `kubectl` via `~/.kube/config` (Omni OIDC, context
  `omni-elysium`). `.claude/secrets/omni.env` was removed; `omnictl` uses the
  interactive session, and `talosctl`'s Omni-issued key **expires often** —
  re-issue with `omnictl talosconfig -c elysium` before any talosctl work.
  `kubectl` needs the `kubectl-oidc_login` plugin: it must be **int128/kubelogin**
  installed under that exact filename, NOT Azure's identically-named `kubelogin`
  (wrong flags → `unknown flag: --oidc-issuer-url`).
- **Assistant/automation access:** scoped read-only ServiceAccount in
  `kubernetes/20-infra-wiring/rbac-claude.yaml`, kubeconfig via
  `infra/elysium/make-claude-kubeconfig.sh`. See CLAUDE.md.
- **Superseded 2026-09-11 status:** cluster synced and up (`omnictl cluster
  template sync`), all 3 machines labeled + matched via
  `infra/elysium/omni/machineclasses.yaml`. Old hal9000 VMs are
  **stopped** (not yet destroyed — keep until elysium is proven). Next:
  Flux bootstrap (README step 6).
- **Scaffolding** (`infra/elysium/` + restructured `kubernetes/`, runbook
  `infra/elysium/README.md`, GitOps `kubernetes/flux/README.md`):
  - `infra/elysium/terraform/` — 3 VMs: `elysium-cp` (apollo 2c/4G/20G),
    `elysium-apollo` (apollo 2c/4G/40G), `elysium-hades` (hades 4c/8G/40G)
  - `infra/elysium/omni/cluster.yaml` — ClusterTemplate, **Talos v1.14.0 /
    k8s v1.37.0** (pinned — fixes virtiofs+SELinux #13245), Flannel
    (Talos default) + kube-proxy, local-path storage, virtiofs on Hades
  - **GitOps: Flux.** `kubernetes/` restructured →
    `flux/clusters/elysium/` (root Kustomizations) →
    `10-infra-base/` (HelmReleases + CRDs) → `20-infra-wiring/`
    (the CRs those CRDs enable + cluster-wide plumbing) →
    `30-apps/{system,home,mediacenter,immich}/` (per-app kustomizations
    with node-placement patches). Undecided apps → `30-apps/_parked/`
    (not built). Tier dirs renamed from `infrastructure/{controllers,
    configs}` + `apps` on 2026-09-12, one root Kustomization file per
    tier so tiers can be enabled one commit at a time.
  - Deleted: `longhorn/`, `monitoring/{loki,grafana}/`, the raw
    cert-manager/VSO manifests. `metallb/`/`nginx-fabric/` were also
    deleted, then **re-added 2026-09-11 as Flux HelmReleases**
    (`kubernetes/10-infra-base/{metallb,nginx-gateway-fabric}.yaml`)
    after reversing the Cilium decision — see CNI bullet below.
  - Global: `kv/hal9000/*` → `kv/elysium/*` in all VaultStaticSecrets;
    `storageClassName: longhorn` → `local-path`. `gatewayClassName` is
    `nginx` (reverted from a brief `cilium` detour, see below).
  - **CNI reversed 2026-09-11: Flannel + MetalLB + nginx-gateway-fabric,
    NOT Cilium.** Cilium was the original plan (also does kube-proxy
    replacement/Gateway API/LB IPAM in one chart) but got dropped because
    replacing the CNI means it can't be an ordinary Flux app — it needs a
    manual by-hand install *before* Flux exists (chicken/egg), which is
    exactly the bootstrap pain this rebuild was trying to remove, plus
    strict version pinning. Flannel/kube-proxy are Talos defaults (zero
    config); MetalLB + nginx-gateway-fabric (2.7.0, Gateway API v1.6.1)
    don't have the chicken/egg problem and are plain HelmReleases. Full
    reasoning in the `k8s-rebuild-elysium` memory.
- **Storage model:** `local-path` (Talos user volume) for pod state. Hades
  media kept as **separate disks** (no mergerfs): sdc=Series → `/mnt/series`,
  sdd=Movies → `/mnt/movies` (`downloads` also lives here, for hardlinked
  movie imports), `odin/photos` — all 4 via **virtiofs** → `elysium-hades`
  only. NFS on Hades turned off. Immich DB stays on the `postgres` VM.
- **Gotcha found this session:** self-hosted Omni's machine-api uses a
  private-CA cert; `omnictl download` (deprecated) can't embed a custom CA
  into installer media, so freshly-booted nodes silently never register
  (no error either side). Fixed via `omnictl media preset create
  --embedded-machine-config-file` (bakes `TrustedRootsConfig` into the ISO).
  Full writeup in the `k8s-rebuild-elysium` memory + README step 2.
- **Open, non-blocking:** `EventsSinkController` on the Talos nodes times
  out dialing Omni's event-sink (port 8091) over the SideroLink WireGuard
  tunnel (`i/o timeout`), even though registration (port 8090, pre-tunnel)
  and the cluster bring-up itself work fine. Likely cause: the VM/host
  firewall for wherever the `omni` container runs allows TCP 443/8090/
  8091/8100 but never got a rule for **UDP/5018** (the actual WireGuard
  port, `--siderolink-wireguard-advertised-addr`) — same "add-one-more-
  privilege" pattern as the Proxmox token saga. Check
  `/etc/pve/firewall/<omni-vmid>.fw` for a `udp dport 5018` ACCEPT.
  Fallback if it's not firewall: rebuild the media preset with
  `--use-siderolink-grpc-tunnel` (tunnels everything over the already-
  working TCP/8090 connection instead of raw UDP — adds overhead, so
  firewall fix is preferred). Not blocking cluster bring-up, just live
  event/log streaming from nodes to Omni.
- **Backups taken** (`hades:/odin/backups/`): home-assistant, plex, sabnzbd.
  mongo (7GB, unknown app) backed up but **not** being restored.
- **Remaining before cutover:** restore data + per-app manifest edits
  (`kubernetes/30-apps/README.md`), un-park `home/` and `mediacenter/`, then
  destroy the stopped hal9000 VMs + `git rm -r infra/hal9000`.
  Vault re-auth and Flux bootstrap are **done**.

#### Disk layout — rebuilt 2026-09-13/14 after a DiskPressure incident
Two disks per worker now, and this is the shape to keep:
- `scsi0` 40G — Talos + **EPHEMERAL, uncapped** (~37G usable). EPHEMERAL backs
  *both* the container image store and `/var/lib/kubelet`, so images, container
  writable layers, pod logs and emptyDirs all compete for it.
- `scsi1` 100G (hades) / 60G (apollo) — the `local-path` user volume, i.e. all
  PVCs. Separate disk so EPHEMERAL can own scsi0 outright, Proxmox can snapshot
  PVC data on its own volume, and a node reset keeps it.
- **What went wrong:** EPHEMERAL was capped at `maxSize: 12GB` with the
  `local-path` user volume provisioned immediately *after* it on the same disk.
  Images alone reached 5.8G. Raising the cap was impossible — a partition can
  only grow into adjacent free space, and the user volume was in the way. A
  `diskSelector` change does **not** migrate or destroy an existing volume, so
  syncing the template achieved nothing; the system disk had to be re-laid-out.
  Fixed by `terraform apply -replace=...` on both workers.
- **Two unbounded writers made it acute** (both fixed): ollama's models on an
  `emptyDir`, and immich-ml downloading CLIP models into its container writable
  layer with no volume at all. Eviction then became self-sustaining — evicted
  pod → ReplicaSet recreates → image pulled again → evicted, leaving 67 dead
  pods whose logs and layers were ~3.4G of the 12G. **Terminated pods are only
  GC'd at 12,500 cluster-wide**, so they accumulate forever here; delete them by
  hand (`kubectl delete pods -n <ns> --field-selector status.phase=Failed`).
- **local-path PVs do not survive a node rebuild** — they carry `nodeAffinity`
  to a node name that no longer exists and the pod stays Pending forever. Delete
  the PVC and let it reprovision. Matters before Home Assistant's SQLite lands
  there: that becomes a restore, not a re-download.
- **`terraform apply -replace` silently drops the virtiofs devices** (telmate
  can't express them). Re-add all five afterwards or immich fails with
  `path "/var/mnt/photos" does not exist`:
  `qm set 1102 --virtiofs0 dirid=series,cache=auto ... --virtiofs4 dirid=immich-cache,cache=auto`

#### Gotchas found bringing Flux up (all fixed, worth not re-learning)
- **Talos enforces PodSecurity `baseline` cluster-wide.** MetalLB's speaker/frr
  and local-path's helper pods need `pod-security.kubernetes.io/enforce:
  privileged` on their namespaces. Without it MetalLB's controller runs while
  the DaemonSets get zero pods and the Helm install hangs until timeout.
- **cert-manager ignores Gateways unless `config.gatewayAPI.enabled: true`.**
  It fails *silently* — no Certificate object is ever created, and the only
  signal is the absence of one. The flag arrives as a ConfigMap
  (`--config=...`), not a CLI arg, so grepping container args is a false negative.
- **MetalLB hands out pool addresses in request order.** On the first deploy
  `external` took `.200` — the address dnsmasq points `*.bgalhardo.internal` at.
  Pinned via Gateway `spec.infrastructure.annotations`
  (`metallb.io/loadBalancerIPs`), which NGF copies onto the Service. Splitting
  the pool into per-gateway `/32`s also works but **cannot be rolled out in one
  commit**: MetalLB's webhook rejects overlapping CIDRs and Flux dry-runs the
  whole set against current state.
- **VSO chart 1.5.1 can't own its own CRs.** `defaultAuthMethod` renders
  `spec.namespace` as YAML null (CRD demands a string) and `defaultVaultConnection`
  makes the Helm release wait on a VaultConnection that can't be healthy until
  Vault trusts the cluster — which would stall tier 1 forever. Both disabled;
  `VaultConnection` + `VaultAuth` declared by hand in
  `20-infra-wiring/vso-config.yaml`. `allowedNamespaces: ["*"]` is required or
  only the operator's own namespace may use them.
- **`Issuer` is namespaced** and tier 2 sets no default namespace. A missing
  `namespace:` surfaces as `the server could not find the requested resource`,
  which reads like a missing CRD. Rule: that error on a CRD that clearly exists
  = missing namespace (a genuinely absent CRD says `no matches for kind`).
- **Vault KV paths reorganised**: `kv/hal9000/*` → `kv/infra/*` (homelab-wide:
  root-ca, the three Cloudflare tokens) + `kv/apps/*` (per-app credentials).
  Nothing is keyed by cluster name any more, so the next rebuild copies no
  secrets. Policy grants both prefixes. Note KV v2's two spellings: policies use
  `kv/data/<path>`, the CLI uses `kv/<path>`.

#### Browser-only TLS failure — split-horizon DNS vs Cloudflare ECH (fixed 2026-09-14)
`immich.bgalhardo.com` failed in Firefox with `SSL_ERROR_UNRECOGNIZED_NAME_ALERT`
while curl worked perfectly. dnsmasq overrides the **A** record to the local
origin but let the **HTTPS/SVCB (type 65)** record fall through to Cloudflare —
and that record advertises **ECH**. Firefox enabled ECH and sent outer SNI
`cloudflare-ech.com` to our nginx, which answered `unrecognized_name`
(`handshake rejected while SSL handshaking` in the NGF log). curl is unaffected
because it doesn't do ECH. Fixed with `filter-rr=65` in
`infra/hermes/dnsmasq.d/custom.conf` (needs dnsmasq ≥ 2.90; hermes runs 2.92).
**Lesson: a partial split-horizon override is a bug** — overriding A while
letting the record that says *how to connect* come from upstream.

Related, still open: the `address=/.bgalhardo.internal/192.168.1.200` wildcard
answers for **any** name under it, so a search-domain-suffixed
`immich.bgalhardo.com.bgalhardo.internal` resolves to the *internal* gateway.
Same class of trap as the "missing record + catch-all wildcard" P0 below.
- **Also at rebuild:** deity names for the Talos nodes if wanted; decide
  keep-or-archive for `home/` voice stack, `gaming/`, `ai/`, `nvidia/`.
- **K8s node labels confirmed working 2026-09-11** (`kubectl get nodes
  --show-labels` — `-o wide` doesn't show them): `elysium-apollo` and
  `elysium-hades` both carry `homelab/node`/`homelab/power` via
  `KubeNodeConfig` patches (`omni/patches/labels-{apollo,hades}.yaml`) on
  their Workers blocks in `cluster.yaml`. The control-plane node has no
  `homelab/node` label (no labels patch on the ControlPlane block) — minor
  gap, trivial to add if wanted. Same pattern for a future GPU node: a new
  `KubeNodeConfig` patch on whichever machine set it lands in.

### ~~Proxmox Read-Only API Access Still Broken~~ ✅ Fixed 2026-08-25
- Upgrading PVE (9.2.3 → 9.2.11) did **not** fix token-scoped ACL
  resolution — confirmed still broken on the newer version.
- Fix: switched `claude@pve!claude-readonly` to `--privsep 0` and moved
  the `PVEAuditor` grant from the token entity to the plain user
  `claude@pve` (matching the already-working `automation@pve` pattern).
  Token now resolves full audit permissions and the API returns real
  data. See network.md's Proxmox API Access section for the root-cause
  writeup — token-scoped (`type: token`, privsep=1) ACL entries appear
  to just never be honored by this PVE build, independent of version.

### Fill in Specifications

**Apollo (Beelink S12 Pro)** — confirmed 2026-08-25 via Proxmox API
(`claude@pve!claude-readonly`, now working — see network.md):
- [x] CPU — **Intel N100**, 1 socket, 4 cores/4 threads
- [x] RAM — **16GB** (15.4 GiB as reported: 16535810048 bytes)
- [x] Storage — 1x NVMe, **Crucial CT1000P3PSSD8, 1TB** (931 GiB usable),
  SMART health PASSED, **69% life remaining (31% worn)** — not urgent,
  but worth a periodic glance since Apollo is the always-on node
- [ ] Power/thermal specs — not exposed via the Proxmox API (no sensor
  data in `/nodes/apollo/status`); would need `sensors` run on-host
- **Why:** Verify sufficient for corosync LXC + K8s + VMs overhead —
  4 cores/16GB confirms this is tight, worth keeping in mind for the
  corosync-LXC migration sizing decision (P0 above)

**Hades (Ryzen 5 PC)** — confirmed 2026-08-25 via Proxmox API:
- [x] CPU — **AMD Ryzen 5 3600**, 1 socket, 6 cores/12 threads
- [x] RAM — **32GB** (31.25 GiB as reported: 33556340736 bytes)
- [x] Storage — full disk picture, confirmed 2026-08-25 via
  `/nodes/hades/disks/list` (not just `/nodes/hades/storage`, which
  only shows Proxmox-registered storage and misses unregistered
  filesystems):
  - `nvme0n1` — WD Blue SN570 1TB, boot/OS drive, 96% SSD life left
  - `sda` + `sdb` — 2x Seagate ST8000DM004 8TB (5400rpm), used by ZFS,
    mirrored into pool **`odin`** (~7.27TB usable, health ONLINE —
    this is the NAS/NFS pool)
  - `sdc` + `sdd` — 2x Seagate ST4000DM004 4TB (5400rpm), **XFS**,
    unpartitioned (no GPT), **not registered as a Proxmox storage** —
    invisible to `/nodes/hades/storage`, only shows up via the raw
    disk list. Purpose/mount point not yet confirmed — worth checking
    `/etc/fstab` on Hades directly.
  - Also present: `local` (dir, ~94GB, PVE OS/ISO/backups) and
    `local-lvm` (LVM-thin, ~795GB) as Proxmox-registered storages.
- **Why:** Resource planning, identify bottlenecks

**Backup PC (TrueNAS):**
- [ ] Hostname
- [ ] IP address (when powered on)
- [ ] Storage capacity
- [ ] TrueNAS version

**K8s Configuration:**
- [x] Kubernetes version — **v1.33.2** (confirmed 2026-08-21 via `kubectl get nodes`)
- [x] Talos version — **v1.10.5**
- [x] Node count — **2** (`talos-y43-va4` control-plane, `talos-y6i-w43`
  worker), IPs `192.168.1.56`/`.57`, both `Ready`, **410 days uptime**
- [ ] Pod CIDR (default: 10.244.0.0/16?)
- [ ] Service CIDR (default: 10.96.0.0/12?)
- **Note:** This is the *pre-rebuild* cluster — `infra/hal9000` is being
  left alone per 2026-08-21 decision; cluster will be rebuilt from
  scratch once `talosctl`/`omnictl` access is granted (see P2 above).
  These specs may be irrelevant post-rebuild.

### Service Deployments (K8s)

**Immich:**
- Design NFS mount points
- Test restore from backup
- Evaluate GPU acceleration (optional)

**Plex:**
- Design NFS mount
- Test with media library
- Monitor performance

**Home Assistant:**
- Migrate from Longhorn to NFS
- Test persistence
- Verify backup strategy

### Corosync LXC Setup
- Create LXC container for qdevice (Alpine)
- Test failover behavior
- Document resource usage
- Effort: 2 hours (after Phase 1 is complete)

## P3: Nice-to-Have (Later)

### Periodic Rotation for All Secrets
- **Task:** Rotate all secrets on a schedule — Vault unseal key, Vault
  root token, Postgres password, Authentik secrets, everything currently
  static in a VM's `.env`
- **Why:** Trivial once compose services pull secrets dynamically from
  Vault instead of a static `.env` (restart picks up a freshly-issued
  value automatically); doing it by hand today means editing `.env` on
  each VM manually, so it doesn't happen. The Vault root token
  specifically is worth rotating/revoking periodically regardless of
  the rest of this — it's the most powerful credential in Vault and
  shouldn't live indefinitely.
- **Blocker:** Depends on wiring compose services to pull secrets from
  Vault directly (dynamic secrets / templated `.env` via
  `vault agent` or similar) instead of today's static per-VM `.env`
  files — that integration doesn't exist yet.
- **Status:** Vision only
- **Benefit:** Removes the whole class of "secret sat unrotated for
  months" issues this session kept surfacing

### K8s High Availability
- **Task:** 3-node control plane. Design refined 2026-09-11 — drop the
  "Pi4 as 3rd node" idea (SD card = bad etcd fsync latency, documented
  risk of corruption/quorum flakiness); a lone CP node should be small,
  cheap, **bare metal** (no Proxmox — Talos is the OS, a hypervisor here
  just adds a second thing to patch/secure for no benefit), with real
  storage (NVMe/eMMC, not SD).
- **Right-sized hardware target:** ~2 cores / 4-8GB RAM (elysium-cp's own
  VM allocation is 2c/4G — a dedicated box doesn't need more).
  Don't buy Apollo-class (4c/16GB) for this — wasted idle capacity.
  Options, cheapest/simplest first:
  - a **smaller N100/N150 mini PC** at a lower RAM config (4-8GB, not 16)
    — x86, no arch mixing, onboard NVMe/eMMC
  - **Pi5 4GB + official NVMe HAT + small NVMe** — Pi5's PCIe lane makes
    this legit (unlike Pi4's USB3-only path); genuinely solves the SD
    problem if a Pi is preferred
  - **Odroid H3/H4** low-RAM variant — x86 SBC built for exactly this
    "Pi-shaped but real storage" niche
- **Depends on:** the netboot/PXE project below — makes a bare-metal CP
  node reprovision-friendly without needing Proxmox's convenience
- **Effort:** 2-3 weeks (unchanged) + hardware purchase
- **Status:** Not planned yet — design refined, hardware not bought
- **Benefit:** True HA for K8s control plane, independent of Apollo

### Re-introduce netboot/PXE for provisioning (2026-09-11)
- **Task:** Bring back TFTP/PXE boot — MAC-keyed, so Terraform (which
  already declares each VM's MAC) stays the single source of truth for
  "what should exist," and network boot handles "what image does it get."
  Removes the manual ISO-download-then-upload-to-Proxmox step for every
  future VM rebuild, and gives Pi provisioning (Hermes-style Alpine
  diskless) the same treatment.
- **Why now:** came out of the elysium rebuild — `omnictl media` presets
  (see `infra/elysium/omni/media-preset.yaml`) can be served over PXE
  directly from Omni (`omnictl media download <preset> --format pxe`),
  no per-node ISO management at all.
- **Shape:**
  - Hermes dnsmasq → **ProxyDHCP mode** (`dhcp-range=192.168.1.0,proxy`) +
    `enable-tftp`/`dhcp-boot`/`pxe-service` — DHCP itself stays on the
    UDM, ProxyDHCP only answers the boot-filename question. The
    directives already exist commented-out in `infra/hermes/dnsmasq.d/custom.conf`.
  - TFTP serves a first-stage loader (`undionly.kpxe`/`ipxe.efi`) →
    chainloads to Omni's PXE URL for Talos machines.
  - Alpine netboot (diskless install) as a second boot-menu entry, for
    Hermes-style Pi provisioning.
- **Note:** `infra/olympus/services/tftp-server/` was deleted 2026-09-08
  as unused — this supersedes that decision with an actual active use.
- **Flagged 2026-09-11 (elysium rebuild): auto-label machines at boot via
  MAC-keyed per-role presets, replacing the manual Omni-UI labeling step.**
  `omnictl media preset create --initial-labels key=value` bakes an Omni
  machine label into a preset — a machine registers pre-labeled, no UI
  click needed, and it's IaC-friendly (every Terraform-recreated VM
  re-registers as a new machine and picks the label up again
  automatically, unlike hand-pasting a UUID into `cluster.yaml`).
  Doing this with static ISOs today would mean managing 3 separate ISO
  files (one per role) — rejected for the current elysium build, labeling
  done manually in the Omni UI instead. netboot removes that cost: PXE
  can pick the boot-filename (and thus which preset/role-labeled image)
  **per MAC**, so each of the 3 elysium VMs' already-static MACs
  (`infra/elysium/terraform/configs.auto.tfvars.json`) maps to its own
  labeled preset with zero extra file management. Supersedes the "all
  Talos nodes share one preset/image" idea above — do 3 presets
  (`elysium-cp`/`elysium-apollo`/`elysium-hades`), each with
  `--initial-labels elysium/role=<role>`, MAC-keyed at the PXE
  boot-filename step.
- **Effort:** small — a few hours, mostly dnsmasq config + testing
- **Status:** Not started — scoped out during the elysium rebuild,
  deliberately kept separate from it
- **Benefit:** no more manual ISO upload/attach per VM, ever; makes
  bare-metal (non-Proxmox) nodes as easy to reprovision as a VM

### GitOps Pipeline for Omni ClusterTemplate (`cluster.yaml`)
- **Task:** Automate `omnictl cluster template sync -f
  infra/elysium/omni/cluster.yaml` on push, instead of running it by hand.
- **Why it's not just "add it to Flux":** Flux reconciles resources
  *inside* the k8s API server (pull-based, because the cluster can reach
  GitHub outbound but nothing needs to reach in). `cluster.yaml` targets
  Omni's own API on a separate VM, authenticated with an **Omni service
  account** (`omnictl serviceaccount create`) — a completely different
  credential Flux never touches, and Omni is only reachable on the
  internal LAN (`omni.bgalhardo.internal`, no public ingress).
- **Implication:** a GitHub-hosted Actions runner can't reach Omni at
  all — this needs a **self-hosted runner** living inside the LAN (same
  reachability constraint that makes Flux pull-based in the first place).
- **Blast-radius concern:** `cluster.yaml` changes carry far more risk
  than an app deploy — this session's whole CNI-patch debugging saga
  (multiple `omnictl cluster template sync` failures from Talos 1.14
  multi-doc config conflicts) is a live example of what a bad patch does.
  Leaning toward: pipeline runs `omnictl cluster template sync --dry-run`
  automatically on every push (drift/errors visible immediately, same
  value `--dry-run` gave during the rebuild), but keep the actual apply
  manual or behind explicit approval, at least until the template's been
  stable for a while.
- **Status:** Design discussion only (2026-09-11) — not started, no
  runner set up yet.

### Agentic DNS Controller
- **Task:** Autonomous DNS based on infrastructure state
- **Effort:** TBD (design phase)
- **Status:** Vision only
- **Benefit:** Self-healing DNS failover

### Agentic Atlas Knowledge Graph
- **Task:** Queryable infrastructure dependencies
- **Effort:** TBD (design phase)
- **Status:** Vision only
- **Benefit:** Machine-understandable infrastructure

### GPU Acceleration for Immich
- **Task:** Use Hades GeForce 750 Ti for transcoding
- **Effort:** 4-6 hours (K8s GPU worker setup)
- **Status:** Future (evaluate after Immich deployment)
- **Benefit:** Faster thumbnail generation, transcoding

## Decisions Made ✅

| Decision | Rationale | Status |
|----------|-----------|--------|
| Corosync → Apollo LXC | Hermes needs Alpine, not Debian | Decided |
| Hermes OS → Alpine | Lightweight, fast boot, minimal resources | Decided |
| DNS independence | Hermes DNS survives cluster outage | Decided |
| Service placement | VMs for core (Vault/Auth), K8s for apps | Decided |
| Deployment method | Static docker-compose per VM, plain `.env` for secrets (Ansible retired 2026-08-21) | Decided |
| Pi4 future role | DNS failover candidate | Decided |
| Hades strategy | Keep as Proxmox + NAS (power-managed) | Decided |

## Decisions Pending ⚠️

| Decision | Options | Impact | Timeline |
|----------|---------|--------|----------|
| Backup PC power | Always-on vs WoL vs N100 | Backup automation | This week |
| Apollo resources | Sufficient for corosync + K8s + VMs? | P0 blocker | This week |
| Immich GPU | K8s worker vs Hades VM? | Performance | Next month |
| External backup location | Home vs friend vs safety deposit? | Offsite strategy | Next month |
| K8s HA control plane | Implement 3-node? | Resilience | Future |

## Status Summary

- **P0 Blockers:** 1 (renewal-automation pattern). Corosync migration done
  2026-09-07; Apollo DNS record downgraded 2026-09-08 (missing record +
  wildcard, low severity).
- **P1 High Priority:** 4 (backup 3-2-1, backup PC decision, Argus
  logging+agent, full VM provisioning / Terraform reconcile)
- **P2 Medium:** Multiple specs to fill, deployments to plan
- **P3 Nice-to-Have:** 4 future enhancements
- **Decision Rate:** 7 made, 5 pending

**elysium (2026-09-14):** Flux + infrastructure done. `system`/`immich`/`ai`
deployed; `home`/`mediacenter` still parked pending data restore. Postgres TLS
was started then deliberately reverted — the pgadmin client is back to
`SSLMode: disable` and `infra/olympus/services/postgres/vault-agent/` is
written but **not wired in**. Note the compose file still carries `ssl=on`
uncommitted: deploying it before the Vault AppRole exists stops postgres from
starting at all.

**Next Step:** Build Vault raft snapshot automation + offsite shipping
for both Vault and Postgres backups (a manual Vault snapshot was taken
2026-08-21, not yet automated).
