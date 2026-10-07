# hephaestus

Headless Blender worker on Hades: Debian LXC, CPU only (the 750 Ti is bound
to `vfio-pci` for VM passthrough). Driven from daedalus over SSH; started and
stopped with `infra/daedalus/hephaestus.sh`.

## 1. LXC (on Hades)

```sh
pveam update && pveam download local debian-13-standard_13.6-1_amd64.tar.zst
```

```sh
pct create 106 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst \
  --hostname hephaestus --cores 12 --cpuunits 50 --memory 16384 --swap 2048 \
  --rootfs local-lvm:32 --net0 name=eth0,bridge=vmbr0,ip=192.168.1.176/24,gw=192.168.1.1 \
  --nameserver 192.168.1.199 --searchdomain bgalhardo.internal \
  --unprivileged 1 --features nesting=1 --onboot 0 \
  --ssh-public-keys <daedalus ~/.ssh/id_ed25519.pub>
pct start 106
```

## 2. Install

From the repo root on daedalus:

```sh
tar -C infra/olympus/services -cf - hephaestus \
  | ssh hades "pct exec 106 -- tar -C /root -xf -"
ssh hades "pct exec 106 -- sh -c 'cd /root/hephaestus && ./install.sh'"
```

On daedalus, `~/.ssh/config`:

```
Host hephaestus
	User root
	Hostname 192.168.1.176
	IdentityFile ~/.ssh/id_ed25519
```

## Use

```sh
infra/daedalus/hephaestus.sh up
scp tools/blender/build.py hephaestus:work/
ssh hephaestus 'blender -b --python work/build.py -- out/'
scp 'hephaestus:out/*' assets/generated/
infra/daedalus/hephaestus.sh down
```
