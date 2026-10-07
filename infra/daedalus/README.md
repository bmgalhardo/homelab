# daedalus — remote agent VM

Scripts that run on daedalus (Apollo VM 101).

| File | Runs on | Does |
|------|---------|------|
| `hephaestus.sh` | daedalus | `up` / `down` / `status` for the Blender LXC on hades (VM or LXC, found by name) |

## Setup

1. Token `daedalus@pve!power` (see `.claude/context/network.md`): copy
   `.claude/secrets/proxmox-power.env.example` to `proxmox-power.env` and
   fill in the secret.
2. Wake-on-LAN on hades: enable it in the BIOS, then on hades
   `ethtool -s <nic> wol g`, persisted with `post-up ethtool -s <nic> wol g` in
   `/etc/network/interfaces` (`<nic>` is `enp10s0`).
3. SSH: the `hephaestus` entry in `~/.ssh/config`, see
   `infra/olympus/services/hephaestus/README.md`.

## Use

```sh
infra/daedalus/hephaestus.sh up
scp tools/blender/build.py hephaestus:work/
ssh hephaestus 'blender -b --python work/build.py -- out/'
scp 'hephaestus:out/*' assets/generated/
infra/daedalus/hephaestus.sh down
```
