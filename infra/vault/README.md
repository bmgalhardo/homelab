# Vault-side setup

Everything here talks **only to Vault**. Nothing in this directory is copied
to a node, and no node can run it.

## Why this isn't in the service directories

A service's Vault Agent needs three Vault-side objects: a **policy**, an
**AppRole**, and (sometimes) a **KV entry**. Creating those is an
administrative act against Vault, not a step in deploying the node — the
node is structurally incapable of doing it, because its own AppRole token is
denied on `auth/approle/role/<role>` by design:

```
$ curl -H "X-Vault-Token: <athena's token>" .../sys/capabilities-self  -d '{"path":"auth/approle/role/athena"}'
"deny"
```

These scripts previously lived in each service's `vault-agent/` directory and
got shipped to the node with the rest of the stack, where they were dead
weight. Consolidated 2026-09-14.

## Layer split

| | where | repeated per node rebuild? |
|---|---|---|
| policy, AppRole, KV entry | Vault raft store | **no** — they outlive the node |
| `role_id` | re-readable any time | no — stable identifier |
| `secret_id` | delivered to the node | **yes** — not retrievable, mint a new one |
| `config.hcl`, `templates/`, `reload.sh` | the service dir | yes — shipped at deploy |
| `ca.crt` | `infra/ca/root-ca.crt` | yes — copied at deploy |

So a reprovisioned node needs **credential delivery**, not a bootstrap.

## Usage

```sh
export VAULT_ADDR=https://vault.bgalhardo.internal   # NOT :8200 — that is plain HTTP
vault login

./approle-bootstrap.sh roles/athena.env                    # create/update
./approle-bootstrap.sh roles/athena.env --print-policy     # show policy, no writes
./approle-bootstrap.sh roles/athena.env --secret-id-only   # rotate / redeliver
```

Idempotent: re-running rewrites the policy and role to the same values, and
the KV seed is guarded so an existing password is never clobbered.

`--print-policy` needs no Vault connection at all — use it to review a change
before applying it.

## Adding a service

Drop a new file in `roles/`:

```sh
ROLE=myservice
COMMON_NAME=myservice.bgalhardo.internal
IP_SAN=192.168.1.x                  # optional — only if clients connect by IP
KV_PATH=kv/data/myservice           # optional — omit for cert-only services
KV_SEED="user=admin password=@random"   # optional — @random generates one
DEPLOY_DIR=/root/myservice
```

Then copy `vault-agent/` from `infra/athena/` into the service dir and adjust
`config.hcl` + `templates/` for the new paths. See
`infra/athena/README.md` → "Vault Agent as a template".

## Scoping rules worth keeping

- **One AppRole + one policy per service.** Never share.
- `allowed_parameters` is a strict allow-list — a parameter not named there is
  rejected, which is why `ip_sans` must be listed even when scoped by value.
- Scope `common_name` to the single host. A compromised node then cannot issue
  a cert impersonating anything else.
- `secret_id_ttl=0` (non-expiring) is a deliberate tradeoff for unattended
  reboots. It is only acceptable because the policy is one-path scoped.
  Phase 5 of `argus.md` tightens this to response-wrapped short-TTL delivery.
