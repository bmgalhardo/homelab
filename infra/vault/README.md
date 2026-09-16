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

Then copy `vault-agent/` from `infra/athena/` into the service dir and adjust
`config.hcl` + `templates/` for the new paths. Deploy steps: `infra/athena/README.md`.

### Policy rules

- One AppRole + one policy per service. Never share.
- `allowed_parameters` is a strict allow-list: a service reached by IP needs
  `IP_SAN`, or issuing with `ip_sans` is rejected.
- Keep each policy to one host and one KV path — `secret_id`s do not expire.

## elysium — kubernetes auth

```sh
./k8s-auth-bootstrap.sh
```

Configures `auth/kubernetes`, the `cert_manager` and `vault-secrets-operator`
policies and roles, and the `vault-ca` Secret the `VaultConnection` trusts.
Needs the admin kubeconfig (it reads the `vault-auth` token Secret) and tier 1
applied. Re-run after a cluster rebuild or a root CA change.
