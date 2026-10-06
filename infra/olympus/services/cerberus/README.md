# cerberus

UniFi Protect live view on Apollo's HDMI port: Debian LXC running go2rtc
(pulls the two camera streams) and a cage + Chromium kiosk showing them.

## 1. Protect

For each camera: Settings → Advanced → RTSPS → enable **Low** or **Medium**,
copy the URL into `.env` (see `.env.example` for the rewrite).

## 2. LXC (on Apollo)

Find the iGPU's card and the template:

```sh
ls -l /dev/dri/by-path/          # pci-0000:00:02.0-card → card0 or card1
pveam update && pveam available | grep debian-13
pveam download local <debian-13-standard template>
```

```sh
pct create <id> local:vztmpl/<debian-13-standard template> \
  --hostname cerberus --cores 2 --memory 1024 --swap 512 \
  --rootfs local-lvm:8 --net0 name=eth0,bridge=vmbr0,ip=192.168.1.175/24,gw=192.168.1.1 \
  --nameserver 192.168.1.199 \
  --unprivileged 1 --features nesting=1 --onboot 1
pct start <id>
pct exec <id> -- getent group video render    # note the render gid
pct set <id> --dev0 /dev/dri/card0,gid=44 --dev1 /dev/dri/renderD128,gid=<render gid>
pct reboot <id>
```

If the card is `card1`, use that in `--dev0` and in `WLR_DRM_DEVICES`
(`kiosk.service`).

## 3. Install

From the repo root on a workstation, with `.env` filled in:

```sh
tar -C infra/olympus/services -cf - cerberus \
  | ssh root@apollo "pct exec <id> -- tar -C /root -xf -"
ssh root@apollo "pct exec <id> -- sh -c 'cd /root/cerberus && ./install.sh'"
```

## Verify

```sh
systemctl status go2rtc kiosk
curl -s http://127.0.0.1:1984/api/streams     # both cams listed with a producer
journalctl -u kiosk -b                        # cage errors show here
```
