# Deployment Strategy

## Model: Static Docker Compose per VM

**Why?** Ansible templating was tried and abandoned (too much overhead
for a homelab; the rendered files drifted from what Ansible's templates
claimed anyway — see Known Issues below). Now: one concrete, static
`docker-compose.yml` per service, committed to git, copied onto its VM
as-is. No rendering step.

Ansible is fully retired — the old playbooks are gone, not archived.
Do not resurrect it without discussion.

### Repo Layout

```
infra/
├── olympus/
│   ├── terraform/         ← VM provisioning (Proxmox), kept — see below
│   └── services/
│       ├── vault/
│       │   ├── docker-compose.yml
│       │   ├── vault.hcl
│       │   ├── unsealer.sh
│       │   ├── bootstrap-k8s-auth.sh  ← Vault-side k8s auth config, see network.md
│       │   └── .env.example    ← names only, real values live in .env on the VM
│       ├── authentik/
│       │   ├── docker-compose.yml
│       │   └── .env.example
│       ├── postgres/
│       │   ├── docker-compose.yml
│       │   ├── backup.sh
│       │   ├── restore.sh
│       │   └── .env.example
│       └── omni/
│           └── docker-compose.yml   ← no secrets baked in, none needed
├── athena/                ← Argus logging+metrics stack (Pi4 node, not Olympus)
│   ├── docker-compose.yml ← vault-agent + loki + prometheus + grafana + alloy
│   ├── vault-agent/       ← agent config + cert/secret templates (node-side only)
│   └── README.md
├── vault/                 ← Vault-side setup. Talks ONLY to Vault; never shipped
│   ├── approle-bootstrap.sh   ← one parameterised script for every service
│   └── roles/<service>.env    ← ROLE / COMMON_NAME / KV_PATH / IP_SAN
├── ca/                    ← root-ca.crt — public, committed on purpose
├── hermes/                ← DNS + LB configs (Pi 1, native Alpine, not compose)
│                            also the SSH bastion since manager was deleted
└── hal9000/terraform/     ← Talos k8s cluster provisioning, kept
```

(There was also an `infra/proxmox/` proxmoxer helper script — removed, gone
as of 2026-09-07. Don't reintroduce it; the Proxmox API is reached directly
with the `claude@pve!claude-readonly` token, see network.md.)

`infra/olympus/terraform/configs.auto.tfvars.json` lists the Olympus VMs:
`postgres`, `vault`, `authentik`, `omni`. (`tftp` removed 2026-09-08;
`netboot` retired 2026-08-21 — both may linger in the drifted tfstate.)

### Access

Direct SSH from a workstation to these VMs does not work (keys aren't
authorized there). The reliable path is via the **hermes** bastion.

> **Changed 2026-09-14:** the `manager` VM (192.168.1.170) was deleted. The
> root SSH keyring now lives on **hermes (192.168.1.199)**, the Pi 1 that
> already serves DNS + HAProxy. Note hermes is therefore three roles on one
> box — DNS, load balancer, and SSH keyring.

```
ssh root@192.168.1.199        # "hermes" — bastion with the real keys
ssh root@vault                # from hermes, its ssh config resolves aliases
ssh root@authentik
ssh root@postgres
ssh root@omni
ssh athena
```

Hermes' `~/.ssh/config` defines: `athena`, `omni`, `vault`, `authentik`,
`postgres`. From a workstation, hermes is the **only** host that answers —
everything else is a second hop.

### Deploy / Update a Service

```sh
# From hermes, or hop through it:
scp infra/olympus/services/<service>/* root@<service>:/root/<service>/
ssh root@<service> "cd /root/<service> && docker compose up -d"
```

Each VM's actual deployment directory is `/root/<service>/` (e.g.
`/root/vault/`, `/root/postgres/`) — confirmed 2026-08-21 by pulling the
live files directly, not assumed from any template. `omni`'s directory
also has `omni.asc` (its private key) sitting alongside the compose file
— never commit it (`.gitignore` excludes `infra/**/*.asc`).

### Secrets

A plain `.env` file lives next to each `docker-compose.yml` **on the
VM only** — never committed. `.env.example` in each service directory
in git lists the variable names so it's clear what's needed:

- `vault`: `VAULT_UNSEAL_KEY`
- `authentik`: `AUTHENTIK_SECRET_KEY`, `PG_PASS`
- `postgres`: `POSTGRES_PASSWORD`
- `omni`: none (all config is non-secret CLI flags)
- `athena` (the logging stack): none in `.env` — uses
  the Vault Agent sidecar (below)

### Vault Agent sidecar (new 2026-09-08, reference: `infra/athena/vault-agent/`)

The plaintext-`.env` model above is the thing the P3 "rotate all secrets"
item is blocked on. The `athena` stack is the first to replace it
with a **Vault Agent sidecar**:

- **Auth:** AppRole (these are VMs, not k8s pods). `role_id` (not secret)
  + `secret_id` (non-expiring bootstrap cred, scoped to a one-path
  policy) as files on the VM. The Vault-side objects are created by
  **`infra/vault/approle-bootstrap.sh roles/<service>.env`** — centralised
  2026-09-14, because that script only ever talks to Vault and the node
  itself is denied on `auth/approle/role/<role>`.
- **Survives a rebuild:** policy, AppRole and KV entry live in Vault. A
  reprovisioned node needs a fresh `secret_id`
  (`--secret-id-only`), not another bootstrap.
- **Secrets:** agent renders `kv/<service>` → `./secrets/<x>.env`, which
  the real container reads via `env_file`.
- **Certs:** agent issues + auto-renews the `pki_infra` leaf cert →
  `./certs/`. Two template stanzas with identical args share one issued
  pair (consul-template caches the write).
- **Reload:** agent touches `./certs/.reload`; a host cron (`reload.sh`)
  restarts the consumers. Keeps the Docker socket out of the agent.

To adopt for another service: copy `vault-agent/` (config + templates), add
`infra/vault/roles/<service>.env`, run the bootstrap. The root CA is a
committed file at `infra/ca/root-ca.crt` — it is public, so there is no
Vault round-trip to fetch it. Full steps in `infra/athena/README.md`.

### hermes (native Alpine, not compose)

DNS + load balancer on the Pi 1. Configs live in `infra/hermes/`
(`dnsmasq.d/custom.conf`, `haproxy.cfg`, `world`, `interfaces`); deploy is
`scp` + `rc-service … restart` + **`lbu commit`**. See its README.

## VM Provisioning (kept as Terraform)

- `infra/olympus/terraform/` — Proxmox VMs for the Olympus (VM) tier:
  vault, authentik, postgres, omni. `configs.auto.tfvars.json` is the
  editable VM spec file (vmid, node, memory, cores, mac — not secret, safe
  in git). `terraform.tfvars` (real Proxmox credentials) and
  `terraform.tfstate*` are gitignored. **State is drifted — see
  `todos.md` "Full VM Provisioning" before running it.**
- `infra/hal9000/terraform/` — Talos k8s cluster VMs. Same pattern.

⚠️ **Known issue:** `infra/olympus/terraform/main.tf` sets
`cipassword = "root"` via cloud-init — every VM gets password auth
enabled with a trivial password, in addition to SSH keys. Flagged in
`todos.md`, not yet fixed.

## Certificate Management

See `.claude/context/network.md` — Vault PKI (`pki_infra`), issued
per-service, no auto-renewal yet.

## Known Issues (as of 2026-08-21 migration)

- No backup automation for Vault at all; Postgres backs up locally but
  doesn't ship offsite. See `todos.md`.
- `authentik`'s compose file points at Postgres by IP
  (`192.168.1.177`), not by `postgres.bgalhardo.internal` DNS — works,
  but brittle if that VM's IP ever changes.
- `omni` has no Terraform/compose provenance trail in the old Ansible
  setup — it was always deployed by hand. Its compose file is genuinely
  static and secret-free as pulled.
