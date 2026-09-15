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
- **Stack written, not deployed** — `infra/athena/`: vault-agent + loki +
  prometheus + grafana + alloy. Next: run `bootstrap-vault-agent.sh`,
  deploy, verify. See `infra/athena/README.md`.
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

## Log Sources & How They Ship

| Source | Method | Notes |
|--------|--------|-------|
| k8s (hal9000) | Alloy DaemonSet | Manifests already exist in `kubernetes/monitoring/alloy/` — repoint `loki.write` at athena (`http://192.168.1.196:3100`) |
| Proxmox hosts (Apollo, Hades) | Alloy native (Debian, apt) | journald + `/var/log/pve*` |
| Olympus VMs (vault, authentik, postgres, omni) | Alloy native or journald→syslog | Docker json-file logs + journald |
| qdevice LXC | Alloy native (Debian) | corosync-qnetd |
| Hermes (Pi 1 B+, Alpine) | **busybox syslogd forwarding** (`-R athena:1514`) | Pi 1 — ARMv6, 512MB, no ARMv6 Alloy build. No loss: dnsmasq + haproxy log to syslog natively. `syslogd` not yet running there — see `infra/hermes/README.md` |
| UDM Pro | UniFi remote syslog export | Settings → System → Remote Logging |

athena runs `loki.source.syslog` on 1514 (Alloy) to receive the last two.

## Fact Probes (no logs involved)

Deliberately low-privilege — this is the argument against colocating on the
bastion (now hermes):

| Fact | Source | Credential |
|------|--------|-----------|
| Node status, ZFS pool health, SMART/wear, storage % | Proxmox API `/nodes/{node}/{status,disks/list,disks/zfs,storage}` | `claude@pve!claude-readonly` (working since 2026-08-25, see network.md) |
| Per-guest RAM: allocated vs used, with history | Proxmox API `/nodes/{node}/{qemu,lxc}/{vmid}/rrddata?timeframe={day,week,month}` — PVE keeps RRD, **no exporter needed**. Flag guests near their allocation ceiling and any host >95%. Confirmed 2026-09-08. | `claude@pve!claude-readonly` |
| Cert expiry (vault, authentik, proxmox, unifi, omni, litellm, ...) | TLS connect, read `notAfter` | **none** |
| Pod/deployment readiness, restart counts, PVC status | k8s API | read-only ServiceAccount (`automation/claude`, live 2026-09-15) |
| **Talos volume health** — `volumestatus` where `phase != running`, reporting `spec.errorMessage` | `talosctl get volumestatus` | Omni service account (`.claude/secrets/omni.env` — **missing, must be restored**) |
| Pod memory vs requests/limits | k8s metrics API (`metrics.k8s.io`) — the one RAM signal invisible from the Proxmox side; flags over/under-provisioned pods | read-only ServiceAccount (new) |
| PKI leaf inventory, seal status | Vault API | read-only policy (new) |
| Cluster quorum | `pvecm status` | SSH — no API equivalent |
| Backup freshness (`/backups/{daily,weekly,monthly}` mtimes) | SSH to `postgres` VM | SSH |

SSH is needed for two things, not everything. Use a dedicated key with
forced commands, not the bastion's keyring.

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
├── vault-agent/                 ← AppRole auth, secret + cert templates, bootstrap + reload
└── README.md                    ← deploy, verify, "Vault Agent as a template"

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

- [ ] **`mem_limit` is silently not enforced.** athena's kernel cmdline has
      `cgroup_disable=memory`, so `/proc/cgroups` has no memory controller
      and Docker discards every limit ("Your kernel does not support memory
      limit capabilities"). `docker stats` reports 0B for all containers.
      The designed ~1.4 GiB ceiling does not exist. Currently harmless —
      the whole stack idles at ~365 MB of 3.8 GB — but nothing stops Loki
      or Prometheus eating the Pi. Fix: drop `cgroup_disable=memory` (add
      `cgroup_enable=memory cgroup_memory=1`) in the boot cmdline, reboot.
- [ ] Prometheus host/cluster scrape targets are commented stubs in
      `prometheus.yml` — wire pve-exporter / node-exporter in Phase 2.

### Phase 2 — Ship logs from everything ☐
- [ ] Alloy DaemonSet in k8s (reuse `kubernetes/monitoring/alloy/`, repoint `loki.write`)
- [ ] Alloy on Apollo + Hades (journald + `/var/log/pve*`)
- [ ] Alloy on the Olympus VMs + qdevice LXC
- [ ] Hermes → busybox syslogd `-R argus:1514` (Pi 1 / ARMv6 — no Alloy)
- [ ] UDM Pro → remote syslog
- [ ] Verify: every host in `network.md` appears as a Loki label
- [ ] **Delete `kubernetes/monitoring/loki/` and `kubernetes/monitoring/grafana/`**
      once the athena stack is serving (agreed 2026-09-07). Keep `alloy/`.

### Phase 3 — Argus agent, first cut ☐
- [ ] Collect: LogQL 24h window + the fact probes above
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
  retention). It scrapes the argus stack itself today; host exporters
  (pve-exporter, node-exporter) and k8s (`kube-state-metrics`) are commented
  stubs in `prometheus.yml`. `kubernetes/monitoring/mimir/` stays retired —
  the node-not-k8s logic still holds. Per-guest RAM pressure is still a fact
  probe (PVE RRD), not a scrape target.

### Resolved

- ~~Hermes Pi model~~ — Pi 1 (ARMv6, 512MB), confirmed 2026-09-07 → syslog, not Alloy
- ~~What happens to the k8s monitoring manifests~~ — delete loki + grafana, keep alloy (2026-09-07)
- ~~Buy a GPU~~ — no, not warranted now (2026-09-07)
