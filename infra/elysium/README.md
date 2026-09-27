# elysium — Talos/k8s cluster (rebuild of hal9000)

Omni owns the cluster; Terraform only builds the VMs. This covers infra
only — VM provisioning through a working, `Ready` Talos cluster. App
deployment continues in `kubernetes/flux/README.md`.

| Node | Proxmox host | vCPU / RAM / disk | Role |
|------|-------------|-------------------|------|
| `elysium-cp` | apollo | 2 / 4G / 20G | control plane (single) |
| `elysium-apollo` | apollo | 2 / 4G / 40G | always-on: Home Assistant, `system` ns, add-ons |
| `elysium-hades` | hades | 4 / 8G / 40G | media: Plex, Immich, *arr, sabnzbd — flaps with Hades power |
| `elysium-hades-gpu` | hades | 4 / 8G / 40G | GTX 750 Ti passthrough — off by default, see [GPU node](#gpu-node) |

- **CNI/LB/Gateway:** Flannel + kube-proxy (Talos defaults — no install
  step here); MetalLB + nginx-gateway-fabric come later as ordinary
  Flux-managed HelmReleases (`kubernetes/flux/README.md`)
- **Storage:** `local-path` (default SC, on a Talos user volume) for pod state; **virtiofs** from Hades for media/photos
- **API VIP:** `192.168.1.180` (unchanged)

```
terraform/   VMs, boot the Omni ISO
omni/        ClusterTemplate + patches (omnictl cluster template sync)
```
App manifests live in `kubernetes/` (bootstrap + apps).

---

### 1. Hades prep (on the Hades PVE host)
```sh
# media disks stay separate (sdc=Series, sdd=Movies, both whole-disk XFS)
cat >> /etc/fstab <<'EOF'
UUID=ef8d89b8-2b6f-43ec-ba23-3c9d66af4fb6  /mnt/series  xfs  defaults,nofail  0 2
UUID=bc54b32b-7d57-4496-bb32-c928f806a21f  /mnt/movies  xfs  defaults,nofail  0 2
EOF
mkdir -p /mnt/series /mnt/movies && mount -a
# downloads on sdd (same disk as Movies -> movie imports hardlink)
mkdir -p /mnt/movies/Downloads
chown 1000:1000 /mnt/series/Series /mnt/movies/Movies /mnt/movies/Downloads
```
PVE Directory Mappings (Datacenter -> Directory Mappings, node=hades):
```
series    -> /mnt/series/Series
movies    -> /mnt/movies/Movies
downloads -> /mnt/movies/Downloads
photos    -> /odin/photos
```

### 2. Talos installer ISO — with the homelab CA embedded
```sh
omnictl media preset create elysium --arch amd64 \
  --talos-version 1.14.0 \
  --extensions siderolabs/qemu-guest-agent \
  --embedded-machine-config-file omni/patches/trusted-ca.yaml \
  --use-siderolink-grpc-tunnel

omnictl media download elysium --output .
```
The preset is a named, server-side resource — re-download anytime without
retyping flags; `omnictl media preset list` / `delete elysium` to manage
it. `omni/media-presets.yaml` holds both presets: `omnictl apply -f` recreates them.
Upload the `.iso` to `local` storage on **both** PVE nodes
(`/var/lib/vz/template/iso/` — Proxmox UI, or `scp`), set `omni_iso` in
`terraform/configs.auto.tfvars.json` to `local:iso/<name>.iso`.

Keep `omni/cluster.yaml` `systemExtensions:` in sync with `--extensions`.

GPU variant for `elysium-hades-gpu` (GTX 750 Ti is Maxwell: proprietary
`nonfree-kmod`, `-lts` branch only — the open modules and `-production`
don't support it). `--initial-labels` skips the manual labeling in step 4:
```sh
omnictl media preset create elysium-nvidia --arch amd64 \
  --talos-version 1.14.0 \
  --extensions siderolabs/qemu-guest-agent \
  --extensions siderolabs/nonfree-kmod-nvidia-lts \
  --extensions siderolabs/nvidia-container-toolkit-lts \
  --initial-labels elysium/role=hades-gpu \
  --embedded-machine-config-file omni/patches/trusted-ca.yaml \
  --use-siderolink-grpc-tunnel

# or recreate it from git: omnictl apply -f omni/media-presets.yaml
omnictl media download elysium-nvidia --output .
scp elysium-nvidia*.iso root@hades.bgalhardo.internal:/var/lib/vz/template/iso/
# then set the node's `iso` in terraform/configs.auto.tfvars.json to local:iso/<that name>
```

### 3. Build the VMs
Needs `terraform/terraform.tfvars` with a Proxmox token that can create VMs
(copy `terraform.tfvars.example`) and the `terraform.tfstate` — both
gitignored, neither in `.claude/secrets/`. The read-only `claude-readonly`
token cannot apply.
```sh
cd infra/elysium/terraform
terraform init && terraform apply
```
virtiofs on elysium-hades — telmate can't express it; either set `pve_ssh`
in tfvars or run on the Hades host:
```sh
for i in 0:series 1:movies 2:downloads 3:photos; do
  qm set 1102 -virtiofs${i%%:*} dirid=${i##*:},cache=auto
done
```

### 4. Bring up the cluster
The 3 VMs register in Omni as available machines. Label each in the Omni
UI (`elysium/role` = `cp` / `apollo` / `hades`) so the MachineClasses in
`machineclasses.yaml` match, then:
```sh
cd ../omni
omnictl apply -f machineclasses.yaml
omnictl cluster template sync -f cluster.yaml
omnictl cluster template status -f cluster.yaml   # wait for Ready
omnictl kubeconfig -f ~/.kube/elysium --cluster elysium
omnictl talosconfig -c elysium
```

Test the Hades virtiofs mount before moving on:
```sh
talosctl -n <elysium-hades ip> get volumestatus   # look for series/movies/downloads/photos, Phase=ready
talosctl -n <elysium-hades ip> list /var/mnt      # each should actually be listed here
```
If `list /var/mnt` is missing entries despite `volumestatus` saying
`ready`, stop+start the vm.

---

Cluster is up and `Ready`. Continue in `kubernetes/flux/README.md` for
Vault re-auth, Flux bootstrap, and app deployment.

## GPU node

`elysium-hades-gpu` (vmid 1103) shares the `nvidia_750ti` PCI mapping with
VM 102 `personal`, and Hades has RAM for only one of them — Proxmox refuses
to start a VM whose mapped device is in use. It is created stopped and never
starts at boot; swap by hand on the Hades host:

```sh
qm shutdown 102 && qm start 1103     # GPU → k8s
qm shutdown 1103 && qm start 102     # GPU → personal
```

Workloads opt in with `runtimeClassName: nvidia` and a `nvidia.com/gpu: 1`
limit. The GPU Operator (`kubernetes/10-infra-base/gpu-operator.yaml`) runs
with its driver/toolkit off — Talos extensions provide both — and schedules
its node components wherever NFD finds an NVIDIA PCI device. Check:
```sh
talosctl -n <ip> read /proc/driver/nvidia/version
kubectl -n gpu-operator get pods      # nvidia-operator-validator Completed
kubectl describe node <node> | grep nvidia.com/gpu
```
