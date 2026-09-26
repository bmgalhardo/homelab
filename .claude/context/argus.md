# Argus — Centralized Logging + Daily Report Agent

**Goal:** Every log in one queryable place, and a 04:00 Telegram report that
tells you what changed. Eventful things get written to a logbook.

**Naming:** `athena` is the **node** (Pi4) and the infra stack on it
(`infra/athena/`, deploy dir `/root/athena/`, Vault AppRole + KV `athena`).
`argus` is the **project/mission** — the report agent (repo-root `argus/`,
Phase 3), the logbook, this doc.

## Current State (2026-09-08)

- **Node `athena` online** — Pi4 4GB, arm64, Alpine 3.24 on a 120GB SATA
  SSD (persistent install), `192.168.1.196` (UniFi fixed), MAC
  `2C:CF:67:64:2C:1D`. Docker installed. `ssh root@192.168.1.196` via the
  **`hermes` bastion (192.168.1.199)** — `manager` was deleted 2026-09-14.
- **Interim VM 208 destroyed**, ~1 GiB reclaimed on Apollo.
- **Hermes dnsmasq updated** — `athena.bgalhardo.internal → .196` live,
  plus the `apollo`/`hades`/`hermes` records and the 8.8.8.8 fallback
  (`infra/hermes/`).
- **Stack deployed 2026-09-14** — `infra/athena/`: vault-agent + loki +
  prometheus + grafana + alloy. See Phase 1 below and `infra/athena/README.md`.
- **Continuing via the hermes bastion** (192.168.1.199).

## Why

The homelab's failure mode is silence, not noise. Everything in `todos.md`
that bit us — 9 expired `pki_infra` leaf certs, Omni's service-account JWT
expired for 46 days, Authentik's SAML signing cert expired for 3 months,
Vault k8s-auth missing `token_reviewer_jwt` for 8 months — produced almost
no log lines. A pure log summarizer would have caught none of them.

So Argus ingests **logs + facts**. Facts are cheap deterministic probes:
cert `notAfter` dates, `pvecm` votes, `zpool status`, SMART wear, backup
file mtimes, disk %, pod readiness. That's where the real incidents live.

## Decisions Made (2026-09-07)

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Logging before agent | Yes — Loki/Alloy first | Agent is much weaker without a queryable substrate |
| Loki placement | **Outside k8s** | k8s outage keeps logs queryable; survives the planned hal9000 rebuild |
| Grafana placement | Same node as Loki | A debugging UI that dies with the cluster is useless |
| Host | **`athena` — Pi4, `192.168.1.196`** | Bare node off the cluster: survives an Apollo failure, arm64 (all images OK), 4GB (stack ceiling ~1.4 GiB). Not the bastion — it holds root SSH keys (that role went to hermes 2026-09-14). Greek-pantheon set with apollo/hades/hermes; Athena = judgment + watchful guardian |
| Report tone | Simple and concise | Terse alert style, not narrative |
| Scope | All infra + all k8s apps; **metrics in scope** | Proxmox, VMs, Hermes, UDM, app-level (Immich, HA, Plex, …). Prometheus is in the athena stack (host/stack metrics; k8s metrics still deferred) |
| Secrets + certs on `athena` | **Vault Agent sidecar** (AppRole) — first implementation, template for every other VM/node | Olympus VMs have no Vault auth today (plaintext `.env`). `infra/athena/vault-agent/` is the reference; unblocks the P3 "rotate all secrets" item. See `deployment.md` |
| Judgment LLM | Claude API | See LLM Split below |
| Code location | This repo | `.claude/context/*.md` is the agent's ground truth for "what normal looks like" |
| Buy a GPU for local judgment | **No — deferred 2026-09-07** | ~€26/yr of API vs €400-700 capex + ~€200/yr power. Revisit only if a GPU is bought for the whole AI/media stack; see analysis below |
| k8s `monitoring/loki` + `grafana` manifests | Delete once the athena stack serves | Agreed 2026-09-07. Keep `alloy/` — it becomes the k8s shipper |
| Per-guest RAM as an Argus signal | Fact probe via **PVE RRD**, not a metrics exporter | `/nodes/*/{qemu,lxc}/*/rrddata` returns day/week/month history for free; only k8s pod-level usage needs the metrics API |

## Architecture

Four stages. Only stage 3 uses an LLM.

```
[1] COLLECT  (deterministic)
    ├─ logs:  Loki via LogQL (24h window)
    └─ facts: Proxmox API, TLS probes, k8s API, Vault API, few SSH calls
                          ↓  ~10⁵-10⁶ lines
[2] REDUCE   (deterministic — 99.9% of volume dies here)
    ├─ drop known-boring (per-source allowlist regex, config/boring.yml)
    ├─ fingerprint: strip timestamps/PIDs/IPs → hash → count
    └─ diff facts against yesterday's snapshot
                          ↓  ~50-300 candidates
[3] JUDGE    (one Claude call)
    ├─ in:  candidates + digest of .claude/context/*.md + open incidents
    └─ out: schema-validated JSON (pydantic)
                          ↓
[4] EMIT
    ├─ Telegram: NEW / ONGOING / RESOLVED; one line on a quiet night
    ├─ logbook/YYYY-MM.md: append only for severity ≥ notable
    └─ state/: fingerprints, fact snapshot, open incidents
```

### Worked example: the failure this design exists for (2026-09-15)

The `local-path` Talos user volume never provisioned on either worker. The
disk selector said `disk.transport == "scsi"`, but these VMs use
`virtio-scsi-single`, so Talos reports the disks as transport **virtio** —
the selector matched nothing and the volume failed at boot.

Why it is the archetypal case:

- **Zero log lines.** Nothing logged anything, anywhere. A log summarizer
  catches none of it.
- **Flux reported healthy, correctly** — the manifests *were* applied and the
  resources exist exactly as declared. The PVC just never binds.
- **The only visible symptom pointed at the wrong component**: `openwebui` in
  CrashLoopBackOff with 423 restarts, which reads like an openwebui bug but
  was only a downstream effect of ollama never starting.
- **It survived 38 hours** on a cluster under active work, and was found by
  accident while deploying an unrelated app.

Where each stage would have caught it:

1. **Facts, not logs.** `PVC phase != Bound` is a one-line deterministic probe.
   It would have fired the morning of 2026-09-14.
2. **State makes it a signal.** A PVC is legitimately Pending for seconds
   during provisioning; *still* Pending against yesterday's snapshot is the
   real event. Without `state/facts.json` this lands in the boring pile.
3. **Judgment correlates it.** Pending PVC + Pending pod + 423 restarts are
   individually weak and together one story — the same shape as the cert →
   Issuer → stale-secret chain this homelab has historically failed at.
4. **Only the Talos probe reports a *cause*.** Every k8s signal is a symptom.
   `spec.errorMessage: no disks matched selector for volume` names the
   component, the failure and the reason in one machine-readable field. This
   is why the Talos probe was added to the table above.

### State is what makes this work

Without memory, the job reports "cert expires in 340 days" for 340 mornings
and you stop reading it by day four — recreating the exact problem it exists
to solve. So:

- `state/fingerprints.json` — hash → `{first_seen, last_seen, count, verdict}`.
  Already-seen-and-judged-boring never reaches the LLM again.
- `state/incidents.json` — open incidents by ID. An ongoing problem
  **updates** its entry, it does not generate a new one.
- `state/facts.json` — yesterday's snapshot, so stage 2 emits *deltas*
  ("pool went DEGRADED", "backup file is 3 days stale") not absolutes.

**The report is a diff against yesterday, not a summary of today.** A quiet
day is one line: `✅ 04:00 — nothing new. 3 open (see logbook).`

Feeding the model `.claude/context/*.md` matters: Hades being unreachable at
04:00 is power management, not an incident, and only the context files know
that.

## Integration List — reviewed 2026-09-16

Every source below was checked against live state on 2026-09-16: Proxmox API
(`claude@pve!claude-readonly`), k8s (`automation/claude`), Omni/Talos (Reader
service account), TLS sweeps of every endpoint, athena's Loki/Prometheus, and
read-only SSH on hermes. **Verdicts are proposed** until the open decisions at
the end of this section are settled.

**Collection principle (proposed):** anything numeric or binary is collected
**continuously in Prometheus**, and the 04:00 agent reads the 24h worst case
(`min_over_time` / `max_over_time`). Agent-side probes are only for facts that
carry a *reason* string (Talos `errorMessage`, Flux/VSO condition messages,
Authentik, backup/snapshot freshness, key expiry). Two reasons:

- Vault was transiently sealed on 2026-09-14; a point-in-time check at 04:00
  would have missed it.
- Hades is power-managed, so its facts need "last observed + age" semantics,
  not "missing".

### Logs

| Source | Verdict | Method | Notes |
|--------|---------|--------|-------|
| k8s pod logs | change | Alloy HelmRelease, `loki.source.kubernetes` (API tail), 1 replica | `kubernetes/monitoring/alloy/` was deleted in `17e511d` — nothing to reuse. API tailing needs no hostPath, so no privileged PSA namespace on Talos |
| k8s events | **add** | Same Alloy, `loki.source.kubernetes_events` | Events expire after 1h — 0 Warning events on 09-16 despite 40+ restarts. This is where `ProvisioningFailed` / `BackOff` live |
| Talos node logs (kubelet, containerd, etcd, machined, kernel) | **add** | Omni patch `machine.logging.destinations` (json_lines over TCP/UDP) | Not pod logs. Receiver on athena not chosen — verify an Alloy component before committing |
| Proxmox hosts (apollo, hades) | keep | Alloy native (apt), journald | Drop `/var/log/pve*` — task failures come from `/cluster/tasks` (fact below) |
| Olympus VMs (vault, authentik, postgres, omni) | change | Alloy container in each VM's compose (`loki.source.docker` + journald) — one template for all | vault and omni are 512 MB; vault had 16 MB free and ~63 MB swapped out on 09-16. Needs vault + omni → 1 GB (open decision) |
| qdevice LXC | **drop** | — | 16 MB RAM, no room for any shipper. Covered by the quorum fact |
| Hermes (Pi 1, ARMv6) | change | HAProxy: `log 192.168.1.196:1514 format rfc5424 local2` direct. dnsmasq: syslog → busybox `syslogd -R` to an RFC3164 listener | On 09-16: syslogd running without `-R`; HAProxy logs to `127.0.0.1 local2` UDP with no listener (lost); dnsmasq logs to a file. Don't ship `log-queries` — volume ≫ signal |
| UDM Pro | keep | UniFi remote syslog | Format unverified — likely RFC3164, same listener as hermes |
| athena's own containers | **add** | `loki.source.docker` on athena's Alloy | vault-agent renewal failures, Loki/Prometheus errors. Cheapest item on the list |

athena needs a second syslog listener: busybox `-R` sends RFC3164 over UDP,
and `alloy/config.alloy` only accepts RFC5424 on 1514.

### Facts

| Fact | Verdict | Source | Credential | Notes |
|------|---------|--------|-----------|-------|
| Node status, ZFS health + last scrub, SMART/wear, storage % | keep | Proxmox API `/nodes/{node}/{status,disks/list,disks/smart,disks/zfs/{pool},storage}` | `claude@pve!claude-readonly` | Verified. For host memory use `available`, not `used` (includes ZFS ARC) |
| Per-guest RAM | change | Proxmox RRD + `status/current` `ballooninfo` | same | Only meaningful with the balloon device on. Guests without it (postgres, elysium-cp confirmed) report host RSS ≈ allocation, so "near ceiling" fires on all of them. Fix: `balloon = memory` in Terraform (stats only, no ballooning) |
| Cert expiry | change | blackbox_exporter on athena, `probe_ssl_earliest_cert_expiry` | none | vault:443, authentik:443, omni:443 + :8100, apollo:8006, hades:8006, proxmox (HAProxy):443, unifi:443, athena:3000, gateways .200/.201 (SNI), couchdb.bgalhardo.com. Postgres:5432 after `ssl=on` needs STARTTLS → agent-side |
| Vault health / seal | change | blackbox on `/v1/sys/health` (503 = sealed), continuous | none | Unauthenticated over 443 (8200 is closed) |
| Vault PKI leaf inventory | **drop** | — | — | `pki_infra/certs` accumulates superseded leaves (athena reissues every ~10 days) → noise; TLS probes cover what is served. Keep a one-off intermediate CA expiry check |
| k8s workload health | extend | k8s API | **new `automation/argus` SA**, same ClusterRole as `claude` | Pod readiness/restarts, PVC phase, **Flux Kustomization/HelmRelease Ready, cert-manager Certificate Ready, VSO `SecretSynced`, Node conditions, Gateway/HTTPRoute Accepted** — RBAC verified for all. Key VSO on `SecretSynced`, not `Ready`. Separate SA: independent revocation, and it lives on a box running an LLM over untrusted logs |
| Talos volume health | keep | `talosctl get volumestatus` via Omni | Omni SA, **Reader** role (`.claude/secrets/omni.env`, restored + verified 09-16) | The only layer that reports a cause (`spec.errorMessage`) |
| Omni SA key expiry | **add** | PGP subkey expiry inside the key — no API call | none | Current key expires **2027-09-15** (1y). todos.md incident #2, on a schedule |
| Pod/container memory | change | kubelet cAdvisor + kube-state-metrics via in-cluster Alloy → `remote_write` | in-cluster | metrics-server is **not installed** (`metrics.k8s.io` empty 09-16). Also avoids the Talos kubelet-serving-cert setup metrics-server needs |
| Cluster quorum | change | Proxmox API `/cluster/status` (quorate) + `/cluster/config/qdevice` (State, last vote) | `claude@pve!claude-readonly` | Verified — removes the `pvecm status` SSH need |
| Proxmox failed tasks | **add** | `/cluster/tasks`, status != OK | same | vzdump / migration failures. 0 in the 7 days to 09-16 |
| Postgres backup freshness | keep | SSH forced command → `stat` newest `/backups/{daily,weekly,monthly}` | dedicated key | Not verified 09-16 (no keyring on hermes) |
| `odin` snapshot age per dataset | **add** | SSH forced command → `zfs list -t snapshot` on hades | dedicated key | The todos.md P0 — fires today (photos 2025-12-03, backups never). Not exposed by the PVE API |
| Authentik SAML signing cert expiry | **add** | Authentik API `/api/v3/crypto/certificatekeypairs/` | read-only Authentik token (new) | Not TLS-visible. Expired 3 months unnoticed (todos.md) |
| DNS | **add** | blackbox DNS probes against hermes (athena, vault, a wildcard name, one external) | none | Hermes DNS is a SPOF with no heartbeat |
| Public DNS drift | **add** | `couchdb.bgalhardo.com` via a public resolver == WAN IP | none | external-dns / cloudflare-ddns fail on Cloudflare timeouts |
| athena host (disk, memory) | **add** | node_exporter on athena | none | No cgroup memory limits (Phase 1 open item) |

SSH remains for exactly two facts (backup mtimes, odin snapshots), via a
dedicated key with forced commands — not a bastion keyring.

### Metrics (Prometheus on athena)

| Target | Verdict | Notes |
|--------|---------|-------|
| athena stack (prometheus, loki, alloy, grafana) | keep | 4/4 up |
| pve-exporter | **drop** | RRD covers guests for the agent, node_exporter covers hosts. Reconsider only for guest charts in Grafana |
| node_exporter — apollo, hades | add | apt `prometheus-node-exporter`; zfs collector gives pool state + ARC size |
| node_exporter — athena | add, priority | Only memory ceiling signal while cgroups are off |
| node_exporter — hermes | skip | `community` repo not enabled; HAProxy exporter + DNS probe give the service view |
| HAProxy built-in exporter (hermes) | add | 3.4.4 is built with `prometheus-exporter` (verified). Proxmox backend up/down |
| blackbox_exporter (athena) | add | Certs, Vault health, DNS, HTTP up for every HTTPRoute |
| elysium (the `hal9000` stub) | add | In-cluster Alloy scrapes kube-state-metrics, cAdvisor, Flux / cert-manager / VSO controller metrics → `remote_write`. Needs `--web.enable-remote-write-receiver`. Drop unneeded cAdvisor series and scrape at 60s, or the 2 GB size cap silently shortens 30d retention |
| Deferred | — | unpoller (UDM, waiting on API key), postgres_exporter, app metrics (Immich, Plex) |

### Found during the review (2026-09-16)

What the list above would have caught — evidence for it, not yet triaged into
todos.md:

- **hermes:** `log-queries` → `/var/log/dnsmasq-debug.log` on the tmpfs root
  (213 MB), 2.7 MB and growing, no rotation; from an uncommitted
  `zz-debug.conf` (`lbu status: A`)
- **hermes:** HAProxy logs lost — UDP to `127.0.0.1`, nothing listening
- **hades:** 25 GB (`personal`) + 8 GB (`elysium-hades`) allocated on a 31 GiB
  host plus ZFS ARC; 727 MB available while `elysium-hades` used only 185 MB
- **vault VM:** 512 MB, 16 MB free, ~63 MB swapped out
- **Vault transiently sealed ~2026-09-14 21:48:** `immich/immich-db`
  VaultStaticSecret still `SecretSynced=False "Vault is sealed"` two days later,
  while `Ready=True`
- `external-dns` 27 restarts (Cloudflare API timeout), `litellm` 9 (last exit
  137, 09-15)
- **apollo NVMe** (Crucial P3 1TB): 33% used, 25.1 TB written, 111 unsafe
  shutdowns — a trend to watch, not an alarm
- hades up 243h — "off at 04:00" did not hold that week
- hermes `~/.ssh` held only `authorized_keys` (changed 09-15 11:39) — no keyring
- Loki had zero labels — nothing ingested yet, including athena itself

### Open decisions

- [ ] Hermes keyring removal — intentional? Postgres backup + odin snapshot
      facts could not be verified without it
- [ ] Raise vault + omni to 1 GB for log shipping (+1 GB on Apollo, at 81%)
- [ ] Adopt the continuous-in-Prometheus collection principle

## LLM Split — local vs Claude API

**Local (existing `kubernetes/ai/` stack):** stage 2 only. `nomic-embed-text`
for embedding-based clustering of near-identical log lines — collapse 4,000
lines into 30 clusters. Small models do this fine and it's the part that
scales with volume.

**Claude API:** stage 3. Correlating "Vault cert expired" → "cert-manager
Issuer failing" → "every VSO secret stale" across three sources is exactly
the reasoning this homelab has historically failed at.

**Not local for judgment (with current hardware).** Apollo is an N100 (4c/16GB)
already carrying the k8s control plane, 5 VMs and the qdevice LXC; `ollama.yml`
caps at 2 CPU/4Gi with `llama3.2:1b`, which won't hold a structured output
schema — confident wrong incident reports are worse than none. Hades has CPU
headroom (Ryzen 5 3600, 32GB) but the GTX 750 Ti is 2GB Maxwell, and Hades is
power-managed and off at 04:00, which would put WoL in the alerting path.

**Cost at ~8k in / 1.5k out, once daily:**

| Model | ~$/day | ~$/month |
|-------|--------|----------|
| Haiku 4.5 | $0.016 | ~$0.50 |
| Sonnet 5 | $0.031 | ~$0.95 |
| Opus 5 | $0.078 | ~$2.35 |

Cost is not the deciding variable — pick on judgment quality. Start on
**Opus 5**, downgrade if reports read fine on Sonnet.

Not worth chasing: Batch API (50% off, but up to 24h turnaround for one daily
call) and prompt caching (5-min TTL, zero hits at one call/day).

### If a GPU gets bought later (analysis 2026-09-07)

Only Hades can take one — Apollo is a mini PC, Hermes is a Pi. **The spec that
matters is VRAM capacity, not compute or bandwidth**: one request/day at ~10k
tokens means even 3 tok/s finishes before you wake up, and the funnel keeps
context at 8-16k so KV cache is small. Budget for weights only.

| VRAM | Model @ Q4_K_M | Verdict for the judgment layer |
|------|----------------|-------------------------------|
| 8GB | 7-8B | No — will confidently invent incidents |
| 12GB | 14B | Marginal; ok at classification, weak at correlation |
| 16GB | 24B (Mistral Small) | Workable floor |
| 24GB | 32B (Qwen3 32B, Gemma 3 27B) | Where local becomes trustworthy here |

Cards: **RTX 4060 Ti / 5060 Ti 16GB** (~€400-500, 165W, idles <12W — best for
an always-on box) or **RTX 3090 24GB used** (~€550-700, 350W, 2.5-3 slots,
wants 750W PSU).

⚠️ **But don't buy one for Argus.** Argus is a ~€26/yr API workload; making
Hades always-on costs ~€165/yr in power before the card (~85W idle: 3600 +
4 HDDs, at ~€0.22/kWh), ~€200/yr with a GPU idling, plus €400-700 capex.
There is no payback path. It only makes sense if the GPU is bought for the
**whole** stack — `whisper`/`piper`/`openwakeword` (manifests exist in
`kubernetes/home/`), Immich ML, Plex transcoding — in which case Argus rides
along free. Separately, Hades always-on has standalone value: it removes the
NFS availability SPOF and softens the qdevice co-location caveat (services.md).

Pre-purchase checks on Hades: PSU wattage (undocumented), free PCIe slot (the
750 Ti is passed through to the Ubuntu workstation VM — worth pulling, 2GB
Maxwell is below any useful floor), physical clearance in the 4U case, and a
Talos worker VM *on Hades* for passthrough (all Talos VMs are on Apollo today
— that's the P3 "K8s GPU worker setup" item). IOMMU already works.

**Call Anthropic directly, not through litellm.** litellm is a k8s service;
routing through it puts the cluster in the critical path of the thing whose
job is to notice the cluster is broken. Treat "litellm unreachable" as a
finding. Use litellm only for the local embedding calls.

## Planned Layout

```
infra/athena/                    ← the stack (built). deploy dir /root/athena/
├── docker-compose.yml           ← vault-agent + loki + prometheus + grafana + alloy
├── loki/config.yml
├── prometheus/prometheus.yml
├── alloy/config.alloy
├── grafana/provisioning/datasources/datasources.yml
├── vault-agent/                 ← AppRole auth, secret + cert templates, reload
└── README.md                    ← deploy, verify

argus/                           ← the agent (repo root), added Phase 3
├── docker-compose.yml
├── .env.example                 ← TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID, ANTHROPIC_API_KEY
├── Dockerfile
├── pyproject.toml
├── argus/
│   ├── collect/                 ← loki.py, proxmox.py, certs.py, k8s.py, vault.py
│   ├── reduce.py                ← fingerprinting + fact diffing
│   ├── judge.py                 ← the single Claude call
│   ├── emit/                    ← telegram.py, logbook.py
│   └── models.py                ← pydantic schemas
└── config/
    ├── sources.yml
    └── boring.yml               ← allowlist, grows over time. This is the real product.
logbook/
└── YYYY-MM.md                   ← one file per month: append-only, never conflicts
```

Python (`httpx` + `pydantic`; talk to the Proxmox API directly — the old
`infra/proxmox/` proxmoxer helper is gone, don't reintroduce it). Both stacks
(`infra/athena/` and the agent) deploy to `athena` via the `scp` +
`docker compose up -d` flow in `deployment.md`. The stack authenticates to
Vault via the `vault-agent` sidecar (AppRole) — no plaintext secrets in
`.env`; see `deployment.md` "Vault Agent sidecar".

**Logbook writes to git:** monthly files are append-only so an agent commit
won't fight a human edit. Give the agent a deploy key scoped to `logbook/`
and `argus/state/` only, with `git pull --rebase` before push.

## Phases

### Phase 1 — logging + metrics stack ✅ (2026-09-14)

**Done (2026-09-08):**

- [x] Node `athena` online — Pi4, `192.168.1.196` (UniFi fixed), Docker
      installed. Interim VM 208 destroyed, ~1 GiB back on Apollo.
- [x] Hermes dnsmasq updated + committed — `athena → .196` live.
- [x] `infra/athena/` written — vault-agent + loki + prometheus + grafana
      + alloy, `mem_limit` on all (~1.4 GiB ceiling), 90d Loki / 30d
      Prometheus, Grafana HTTPS via the vault-agent cert.
- [x] `infra/athena/vault-agent/bootstrap-vault-agent.sh` — creates the
      `athena` AppRole + policy (read `kv/athena`, issue the one leaf
      cert), seeds `kv/athena`.

**Done (2026-09-14) — Phase 1 complete:**

- [x] AppRole bootstrapped. Script centralised to
      `infra/vault/approle-bootstrap.sh roles/athena.env` — it only ever
      talks to Vault, and the node is denied on `auth/approle/role/athena`
      by design, so it never belonged in the node's deploy dir.
- [x] Root CA committed at `infra/ca/root-ca.crt` (public; the private key
      stays in Vault). Replaces the old `vault read pki_root/cert/ca` step.
- [x] Deployed to `/root/athena/`, `docker compose up -d`, `reload.sh`
      cron installed (`*/5`).
- [x] **Exit checks all pass:** Loki `ready`; Prometheus healthy; Loki
      write→read round-trip OK (push 204, query matched); Grafana serving
      HTTPS on a Vault-issued leaf (`CN=athena.bgalhardo.internal`, issued
      by `Intermediate CA [infra]`, 360h TTL, auto-renewed by vault-agent);
      cert verifies against the root CA (rc=200); all 4 Prometheus targets
      `up` (prometheus, loki, alloy, grafana).
- [x] AppRole verified end-to-end: login OK, reads its own KV, issues its
      own cert, denied on every other path tested.

**Open from Phase 1:**

- [ ] **No memory ceiling on the stack.** athena's kernel cmdline has
      `cgroup_disable=memory`, so `/proc/cgroups` has no memory controller and
      Docker silently discards every `mem_limit` ("Your kernel does not
      support memory limit capabilities"); `docker stats` reports 0B for all
      containers. The `mem_limit` lines were therefore removed from the compose
      file (2026-09-16) rather than left as decoration. Currently harmless —
      the whole stack idles at ~365 MB of 3.8 GB — but nothing stops Loki or
      Prometheus eating the Pi, which matters once Phase 2 starts shipping real
      log volume. Fix: drop `cgroup_disable=memory` (add
      `cgroup_enable=memory cgroup_memory=1`) in the boot cmdline and reboot,
      then restore the limits.
- [ ] Prometheus host/cluster scrape targets are commented stubs in
      `prometheus.yml` — wire them per the Integration List metrics table
      (pve-exporter proposed dropped).

### Phase 2 — Ship logs + metrics from everything ☐

Order from the 2026-09-16 review — see Integration List for the method per source.

- [ ] athena: `loki.source.docker`, RFC3164 syslog listener, node_exporter,
      blackbox_exporter
- [ ] hermes: remove debug `log-queries`, HAProxy logs direct to athena,
      `syslogd -R`, HAProxy exporter, `lbu commit`
- [ ] k8s: Alloy HelmRelease — pod logs, events, `remote_write` of
      kube-state-metrics + cAdvisor; `automation/argus` ServiceAccount
- [ ] Proxmox hosts: Alloy (journald) + node_exporter
- [ ] Olympus VMs: Alloy compose template (after the RAM decision)
- [ ] Talos node logs via `machine.logging.destinations`
- [ ] UDM Pro → remote syslog
- [ ] Verify: every host in `network.md` appears as a Loki label
- [x] `kubernetes/monitoring/` is gone (removed in `17e511d`, flux first
      stage) — no loki/grafana left to delete, and no alloy to reuse

### Phase 3 — Argus agent, first cut ☐
- [ ] Collect: LogQL 24h window + the Integration List facts
- [ ] Reduce: fingerprinting + fact diff
- [ ] Judge: one Claude call, pydantic-validated structured output
- [ ] Emit: Telegram only (no state yet)
- [ ] Cron 04:00

### Phase 4 — State + logbook ☐
- [ ] `state/` fingerprints, facts, incidents
- [ ] NEW / ONGOING / RESOLVED framing
- [ ] `logbook/YYYY-MM.md` writes + deploy key
- [ ] `boring.yml` tuning — expect 2 noisy weeks, that's normal

### Phase 5 — Hardening ☐
- [ ] Dead-man's switch: ping healthchecks.io on success. **Telegram cannot
      report its own absence** — silence must be distinguishable from a quiet night
- [ ] Move `ANTHROPIC_API_KEY` / Telegram token into Vault
- [ ] Restricted SSH key with forced commands (drop the bastion keyring)

## Open Questions

- Loki retention: 90d assumed. Storage is cheap here (~1-3GB), could go longer.
- Does Argus report on itself? A stuck collector or a failed Claude call needs
  to surface somewhere other than the report it just failed to send. Partly
  covered by the Phase 5 dead-man's switch — decide if that's enough.
- Metrics: **Prometheus is now in the argus stack** (2026-09-08, 30d/2GB
  retention). It scrapes the argus stack itself today; the target list is in
  the Integration List metrics table (2026-09-16). Mimir stays retired — the
  node-not-k8s logic still holds. Per-guest RAM pressure is still a fact
  probe (PVE RRD), not a scrape target.

### Resolved

- ~~Hermes Pi model~~ — Pi 1 (ARMv6, 512MB), confirmed 2026-09-07 → syslog, not Alloy
- ~~What happens to the k8s monitoring manifests~~ — delete loki + grafana, keep alloy (2026-09-07)
- ~~Buy a GPU~~ — no, not warranted now (2026-09-07)
