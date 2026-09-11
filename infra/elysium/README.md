# elysium — Talos/k8s cluster (rebuild of hal9000)

Omni owns the cluster; Terraform only builds the 3 VMs. This covers infra
only — VM provisioning through a working, `Ready` Talos cluster. App
deployment continues in `kubernetes/flux/README.md`.

| Node | Proxmox host | vCPU / RAM / disk | Role |
|------|-------------|-------------------|------|
| `elysium-cp` | apollo | 2 / 4G / 20G | control plane (single) |
| `elysium-apollo` | apollo | 2 / 4G / 40G | always-on: Home Assistant, `system` ns, add-ons |
| `elysium-hades` | hades | 4 / 8G / 40G | media: Plex, Immich, *arr, sabnzbd — flaps with Hades power |

- **CNI/LB/Gateway:** Flannel + kube-proxy (Talos defaults — no install
  step here); MetalLB + nginx-gateway-fabric come later as ordinary
  Flux-managed HelmReleases (`kubernetes/flux/README.md`)
- **Storage:** `local-path` (default SC, on a Talos user volume) for pod state; **virtiofs** from Hades for media/photos
- **API VIP:** `192.168.1.180` (unchanged)

```
terraform/   3 VMs, boot the Omni ISO
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
it. Upload the `.iso` to `local` storage on **both** PVE nodes
(`/var/lib/vz/template/iso/` — Proxmox UI, or `scp`), set `omni_iso` in
`terraform/configs.auto.tfvars.json` to `local:iso/<name>.iso`.

Keep `omni/cluster.yaml` `systemExtensions:` in sync with `--extensions`.

### 3. Build the VMs
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
