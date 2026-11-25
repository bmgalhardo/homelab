# gaia

Single-node Talos cluster on Apollo for the core services (Vault, Postgres,
Authentik, Omni). Standalone Talos, not managed by Omni. Flux reconciles
`kubernetes/gaia/`.

| | |
|---|---|
| VM | `gaia`, VMID 1200, Apollo, 2 cores, 4 GB |
| Disks | `scsi0` 20G system (Talos + EPHEMERAL), `scsi1` 30G `local-path` volume |
| Node IP | `192.168.1.172` (static, set in the Talos config) |
| Talos | v1.14.1, Image Factory schematic `talos/schematic.yaml` |

## Build

1. Talos ISO on Apollo (schematic id from `talos/schematic.yaml`):

   ```sh
   ID=ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515
   pvesh create /nodes/apollo/storage/local/download-url --content iso \
     --filename gaia-1.14.1-${ID:0:6}.iso \
     --url https://factory.talos.dev/image/$ID/v1.14.1/metal-amd64.iso
   ```

2. VM (module `infra/modules/talos-vm`, shared with elysium):

   ```sh
   infra/tf.sh gaia init
   infra/tf.sh gaia apply
   ```

3. Talos. The VM boots the ISO into maintenance mode with a DHCP address
   (Proxmox console, or `qm guest cmd 1200 network-get-interfaces` on Apollo):

   ```sh
   ./bootstrap.sh install /path/to/gaia-secrets-*.age <maintenance-ip>
   ```

   It renders the config from `talos/patch.yaml` + the archive's Talos
   secrets + `infra/ca/root-ca.crt`, applies it, bootstraps etcd and applies
   the archive's `k8s/` Secrets. The node comes up on `192.168.1.172`.
   `./bootstrap.sh creds ARCHIVE` rewrites the admin kubeconfig to
   `~/.kube/gaia` and the talosconfig to `~/.talos/gaia`.

## Secrets

Not in git. One archive, encrypted with an `age` passphrase (kept in
Bitwarden), in Hades `/odin/backup/gaia/`. Keep a second copy off Hades.

| File in the archive | Holds |
|---|---|
| `talos-secrets.yaml` | Talos cluster secrets (`talosctl gen secrets`) |
| `k8s/vault-unseal.yaml` | `vault/vault-unseal` |
| `k8s/authentik-secret-key.yaml` | `authentik/authentik-secret-key` |
| `k8s/omni-asc.yaml` | `omni/omni-asc` (Omni etcd encryption key) |
| `k8s/omni-oidc.yaml` | `omni/omni-oidc` (Authentik client) |

`secrets.sh unpack FILE DIR` decrypts it (rebuild, or to change a secret);
`secrets.sh pack DIR` encrypts a folder and copies it to Hades.
