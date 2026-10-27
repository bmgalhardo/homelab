# homelab

A 2-node Proxmox cluster (Olympus) running a small VM tier plus a Talos
Kubernetes cluster (hal9000), fully in code. See [`AGENTS.md`](AGENTS.md) for the current
architecture, conventions, and open priorities in detail.

## tech stack

Provisioning
- Proxmox: hypervisor
- Terraform: VM + Talos cluster provisioning (`infra/{olympus,hal9000}/terraform`)

Platform
- Kubernetes (Talos Linux) for apps — manifests in `kubernetes/`
- Static Docker Compose per VM for core services (Vault, Postgres,
  Authentik, Omni) — `infra/olympus/services/`

Networking (K8s)
- MetalLB: layer-2 load balancer
- NGINX Gateway Fabric: Gateway API ingress
- external-dns, cert-manager: DNS + TLS automation

Storage
- Longhorn: block storage for K8s
- NFS (from Hades) for larger media/photo volumes

Auth and secrets
- Vault: PKI + secrets, synced into K8s via vault-secrets-operator
- Authentik: SSO

## Working with Claude Code and Codex

This repo supports both Claude Code and Codex — both for infra-as-code
changes (Terraform, K8s manifests, compose files) and for live debugging
against the running cluster.

`AGENTS.md` holds the shared instructions; `CLAUDE.md` is a symlink to it.
`.agents/` holds shared files, with `.claude/` as a compatibility symlink.
Both assistants use the same scoped access and read-only defaults described
in `AGENTS.md`. Local credentials stay gitignored in `.agents/secrets/`.

`AGENTS.md` and `.agents/context/` are maintained as persistent operating
context: hardware, network, services, storage and deployment docs kept
current so an unfamiliar corner of the infra can be picked up without
re-deriving it from scratch. `plans/todos.md` tracks the open roadmap and known
blockers.

## Repo layout

- `infra/olympus/terraform/`, `infra/hal9000/terraform/` — VM/cluster provisioning
- `infra/olympus/services/` — static compose files for the VM tier
- `kubernetes/` — manifests for the hal9000 cluster
- `.agents/context/` — detailed, living infra docs (network, services,
  storage, deployment, backup, todos)

No secrets are committed — `.env` per VM stays on the VM (gitignored,
`.env.example` tracked for the variable names); everything else lives in
Vault. See `.gitignore` before adding anything under `infra/`.
