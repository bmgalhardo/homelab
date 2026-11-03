# Proxmox hosts — apollo, hades

Host-level agents on the Proxmox nodes themselves (not VMs). Debian 13 / PVE 9.

| Agent | Port | Ships to |
|-------|------|----------|
| `prometheus-node-exporter` (upstream binary, Debian service) | 9100 | scraped by Prometheus on athena |
| `alloy` (apt.grafana.com) | 127.0.0.1:12345 | journald → Loki on athena |

| repo | on host |
|------|---------|
| `config.alloy` | `/etc/alloy/config.alloy` |
| `alloy-limits.conf` | `/etc/systemd/system/alloy.service.d/limits.conf` |
| `cpu-governor.service` | `/etc/systemd/system/cpu-governor.service` (apollo) |

## Install

```sh
H=apollo   # or hades
ssh $H '
  apt-get install -y prometheus-node-exporter gpg &&
  mkdir -p /etc/apt/keyrings &&
  wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg &&
  echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list &&
  apt-get update -o Dir::Etc::sourcelist=sources.list.d/grafana.list -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0;
  apt-get install -y alloy &&
  usermod -aG systemd-journal alloy &&
  mkdir -p /etc/systemd/system/alloy.service.d
'
scp infra/olympus/hosts/config.alloy      $H:/etc/alloy/config.alloy
scp infra/olympus/hosts/alloy-limits.conf $H:/etc/systemd/system/alloy.service.d/limits.conf
ssh $H "grep -q ^HOSTNAME= /etc/default/alloy || echo HOSTNAME=$H >> /etc/default/alloy &&
  alloy validate /etc/alloy/config.alloy &&
  systemctl daemon-reload && systemctl enable --now alloy && systemctl restart alloy"
```

Then add `<ip>:9100` to the `node` job in `infra/athena/prometheus/prometheus.yml`.

## Node exporter upgrade

```sh
ssh root@192.168.1.197 'sh -s' < infra/olympus/hosts/install-node-exporter.sh
ssh root@192.168.1.198 'sh -s' < infra/olympus/hosts/install-node-exporter.sh
```

The installer verifies the pinned upstream archive checksum and selects the
versioned binary through a systemd drop-in. The Debian package supplies the
service and user; arguments remain in `/etc/default/prometheus-node-exporter`.

## k8s backup target (hades)

SFTP-only drop for in-cluster apps: dataset `odin/k8s-backups` (200G quota),
one chrooted user per client writing to `/odin/k8s-backups/<client>`, key auth
only.

| repo | on host |
|------|---------|
| `sshd-k8s-backups.conf` | `/etc/ssh/sshd_config.d/k8s-backups.conf` |
| `k8s-backup-client.sh` | run once per client |

```sh
C=homeassistant
ssh-keygen -t ed25519 -N '' -C "$C-backup" -f ~/$C-backup        # keep it off-cluster
scp infra/olympus/hosts/sshd-k8s-backups.conf hades:/etc/ssh/sshd_config.d/k8s-backups.conf
scp infra/olympus/hosts/k8s-backup-client.sh ~/$C-backup.pub hades:/tmp/
ssh hades "sh /tmp/k8s-backup-client.sh $C /tmp/$C-backup.pub && rm /tmp/k8s-backup-client.sh /tmp/$C-backup.pub"
echo pwd | sftp -i ~/$C-backup -b - $C@192.168.1.198               # expect /homeassistant
```

## Photos mirror (apollo ↔ hades)

Apollo `/mnt/immich` is the live Immich library. Hades, on boot and daily,
pulls `immich/` and `immich-cache/` into `/odin/photos/` and pushes
`archive_public/` (source of truth on hades) to apollo. `sanoid` snapshots
`odin/photos`. Apollo side is user `photos-backup` with two `rrsync` keys:
`pull` read-only on `/mnt/immich`, `push` write-only scope
`/mnt/immich/archive_public`.

| repo | on host |
|------|---------|
| `photos-mirror.sh` | hades `/usr/local/bin/photos-mirror` |
| `photos-mirror.{service,timer}` | hades `/etc/systemd/system/` |
| `sanoid.conf` | hades `/etc/sanoid/sanoid.conf` |

```sh
A="ssh root@192.168.1.197"; H="ssh root@192.168.1.198"
$H 'install -d -m 700 /etc/photos-mirror && for k in pull push; do
  ssh-keygen -q -t ed25519 -N "" -C photos-mirror-$k@hades -f /etc/photos-mirror/$k; done'
PULL=$($H cat /etc/photos-mirror/pull.pub); PUSH=$($H cat /etc/photos-mirror/push.pub)
$A "id photos-backup >/dev/null 2>&1 || useradd --system --home-dir /var/lib/photos-backup --create-home --shell /bin/sh photos-backup
  install -d -o photos-backup -m 700 /var/lib/photos-backup/.ssh
  chown -R photos-backup /mnt/immich/archive_public
  printf '%s\n' 'command=\"/usr/bin/rrsync -ro /mnt/immich\",restrict $PULL' \
    'command=\"/usr/bin/rrsync /mnt/immich/archive_public\",restrict $PUSH' \
    > /var/lib/photos-backup/.ssh/authorized_keys
  chown photos-backup /var/lib/photos-backup/.ssh/authorized_keys; chmod 600 /var/lib/photos-backup/.ssh/authorized_keys"
echo "192.168.1.197 $($A cat /etc/ssh/ssh_host_ed25519_key.pub | cut -d' ' -f1-2)" |
  $H 'cat > /etc/photos-mirror/known_hosts'
scp photos-mirror.sh root@192.168.1.198:/usr/local/bin/photos-mirror
scp photos-mirror.service photos-mirror.timer root@192.168.1.198:/etc/systemd/system/
$H 'apt-get install -y sanoid && install -d /etc/sanoid'
scp sanoid.conf root@192.168.1.198:/etc/sanoid/sanoid.conf
$H 'systemctl daemon-reload && systemctl enable --now sanoid.timer photos-mirror.timer &&
  systemctl start photos-mirror && journalctl -u photos-mirror -n 5 --no-pager'
```

## CPU governor (apollo)

```sh
scp infra/olympus/hosts/cpu-governor.service apollo:/etc/systemd/system/
ssh apollo 'systemctl daemon-reload && systemctl enable --now cpu-governor &&
  cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
```

Anything else that sets the governor at boot wins over this unit:
`crontab -l` (`@reboot ... performance`), `/etc/default/cpufrequtils`.
