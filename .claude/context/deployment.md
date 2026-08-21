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
│       ├── omni/
│       │   └── docker-compose.yml   ← no secrets baked in, none needed
│       └── tftp-server/
│           └── README.md            ← not compose — native apk install, see below
├── hal9000/terraform/     ← Talos k8s cluster provisioning, kept
└── proxmox/               ← small proxmoxer/pydantic helper script, WIP
```

`infra/olympus/terraform/configs.auto.tfvars.json` is the source of
truth for which VMs exist: `tftp`, `netboot` (retired), `postgres`,
`vault`, `authentik`, `omni`.

### Access

Direct SSH from a workstation to these VMs may not work (keys aren't
necessarily authorized there). The reliable path is via the **manager**
host:

```
ssh root@192.168.1.170        # "manager" — jump host with the real keys
ssh root@vault                # from manager, hostnames resolve directly
ssh root@authentik
ssh root@postgres
ssh root@omni
ssh root@tftp
```

### Deploy / Update a Service

```sh
# From manager, or hop through it:
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

### tftp-server

Not a compose service — a native Alpine host running `tftp-hpa` plus a
static `undionly.kpxe` binary in `/var/tftpboot/`. Setup steps are in
`infra/olympus/services/tftp-server/README.md`. Nothing to template, nothing to
containerize.

## VM Provisioning (kept as Terraform)

- `infra/olympus/terraform/` — Proxmox VMs for the Olympus (VM) tier:
  vault, authentik, postgres, omni, tftp, netboot. `configs.auto.tfvars.json`
  is the editable VM spec file (vmid, node, memory, cores, mac — not
  secret, safe in git). `terraform.tfvars` (real Proxmox credentials) and
  `terraform.tfstate*` are gitignored.
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
