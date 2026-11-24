# Vault-side setup

Scripts that configure Vault itself: auth methods, policies, roles, KV seeds.
They talk only to Vault (and to elysium, for kubernetes auth). Nothing here is
copied to a node.

```sh
cd infra/vault
export VAULT_ADDR=https://vault.bgalhardo.internal   # NOT :8200 — that is plain HTTP
export VAULT_CACERT=$PWD/../ca/root-ca.crt           # unless the root CA is in your system store
vault login
```

## Nodes and VMs — AppRole for Vault Agent

```sh
./approle-bootstrap.sh roles/athena.env                    # create/update
./approle-bootstrap.sh roles/athena.env --print-policy     # show policy; no writes, no Vault needed
./approle-bootstrap.sh roles/athena.env --secret-id-only   # rotate / redeliver
```

Idempotent: re-running rewrites the policy and role to the same values, and an
existing KV entry is never overwritten.

What a rebuilt node needs:

| | where | redo on node rebuild? |
|---|---|---|
| policy, AppRole, KV entry | Vault | no |
| `role_id` | re-readable any time | no |
| `secret_id` | delivered to the node | **yes** — `--secret-id-only` |
| `config.hcl`, `templates/`, `reload.sh` | the service dir | yes — shipped at deploy |
| `ca.crt` | `infra/ca/root-ca.crt` | yes — copied at deploy |

### Adding a service

Drop a new file in `roles/`:

```sh
ROLE=myservice
COMMON_NAME=myservice.bgalhardo.internal
IP_SAN=192.168.1.x                      # optional — only if clients connect by IP
KV_PATH=kv/data/myservice               # optional — omit for cert-only services
KV_SEED="user=admin password=@random"   # optional — @random generates one
DEPLOY_DIR=/root/myservice              # default /root/<ROLE>
```

A role without `COMMON_NAME` gets no PKI path. Optional token settings:
`TOKEN_TTL` (default 1h), `TOKEN_MAX_TTL` (0), `TOKEN_PERIOD` (1h; 0 = not
periodic), `SECRET_ID_CIDRS` (binds the secret_id and its tokens to these
addresses), `CRED_DIR` (where the printed delivery commands write).

## Agents — the `claude` role

`roles/claude.env`: read-only on `kv/agents/*`, bound to daedalus
(192.168.1.170), tokens of 8h. One entry per service, under
`kv/agents/<service>`: `unifi`, `homeassistant`, `forgejo`, `kube`,
`proxmox`, `proxmox-power`, `omni`.

```sh
./approle-bootstrap.sh roles/claude.env   # deliver to ~/.config/vault/claude/ on daedalus
./seed-agents-kv.sh --dry-run             # key names only
./seed-agents-kv.sh                       # files in .agents/secrets/ -> kv/agents/*
```

Rotating a credential: `vault kv patch -mount=kv agents/<service> <key>=@<file>`.
Cluster credentials (kubeconfigs, gaia's talosconfig) are written straight
into `kv/agents/*` by `infra/make-claude-creds.sh`.

Then copy `vault-agent/` from `infra/athena/` into the service dir and adjust
`config.hcl` + `templates/` for the new paths. Deploy steps: `infra/athena/README.md`.

### Policy rules

- One AppRole + one policy per service. Never share.
- `allowed_parameters` is a strict allow-list: a service reached by IP needs
  `IP_SAN`, or issuing with `ip_sans` is rejected.
- Keep each policy to one host and one KV path — `secret_id`s do not expire.

## Kubernetes auth

```sh
./k8s-auth-bootstrap.sh <cluster>   # elysium | gaia
```

elysium: `auth/kubernetes`, the `cert_manager` and `vault-secrets-operator`
policies and roles, and the `vault-ca` Secret the `VaultConnection` trusts.
gaia: `auth/kubernetes-gaia` with only the cert-manager `issuer` role.
Needs the admin kubeconfig (it reads the `vault-auth` token Secret) and tier 1
applied. Re-run after a cluster rebuild or a root CA change.
