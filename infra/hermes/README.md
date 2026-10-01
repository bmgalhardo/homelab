# hermes — DNS + load balancer (independent utility node)

Raspberry Pi **1** Model B+ (ARMv6, 512 MB, single core), Alpine **diskless**
(`lbu`, boot media `mmcblk0p1`). Deliberately independent of the Proxmox
cluster — DNS survives a cluster outage. See `.claude/context/network.md`.

- **IP:** `192.168.1.199` static
- **Runs:** `dnsmasq` (DNS only — DHCP is the UDM Pro), `haproxy` (TLS-SNI
  router, metrics on `:8405/metrics`), `node-exporter` (`:9100`), plus
  `sshd` / `ntpd` / `crond`.
  Logs (syslog + HAProxy) ship to athena `:1515`
- **Packages:** `world` (7 explicit — ARMv6 needs busybox-native or
  built-from-source; no Docker, no Alloy)

| repo | on hermes |
|------|-----------|
| `dnsmasq.d/custom.conf` | `/etc/dnsmasq.d/custom.conf` (mode 644) |
| `haproxy.cfg` | `/etc/haproxy/haproxy.cfg` |
| `interfaces` | `/etc/network/interfaces` |
| `world` | `/etc/apk/world` |
| `repositories` | `/etc/apk/repositories` — community enabled for `prometheus-node-exporter` |
| `syslog` | `/etc/conf.d/syslog` — busybox syslogd keeps local + forwards to athena:1515 |


## Deploy a change

```sh
scp infra/hermes/dnsmasq.d/custom.conf root@192.168.1.199:/etc/dnsmasq.d/custom.conf
scp infra/hermes/haproxy.cfg           root@192.168.1.199:/etc/haproxy/haproxy.cfg
scp infra/hermes/syslog                root@192.168.1.199:/etc/conf.d/syslog
ssh root@192.168.1.199 '
  chmod 644 /etc/dnsmasq.d/custom.conf &&
  haproxy -c -f /etc/haproxy/haproxy.cfg &&
  rc-service dnsmasq restart &&
  rc-service haproxy restart &&
  rc-service syslog restart &&
  lbu commit                                   # <-- REQUIRED or a reboot reverts it
'
```

Verify DNS: `dig +short @192.168.1.199 athena.bgalhardo.internal` → `192.168.1.196`
(deployed + `lbu commit`'d 2026-09-08).

## HAProxy cert

`haproxy.cfg` loads `/etc/haproxy/certs/` for the TLS-termination frontend.
One cert today: `authentik.bgalhardo.internal.pem` (leaf **+** private key
concatenated, PEM). Reissue from Vault:

```sh
vault write -format=json pki_infra/issue/internal \
  common_name=authentik.bgalhardo.internal ttl=360h > /tmp/a.json
jq -r '.data.certificate, .data.private_key' /tmp/a.json \
  > /etc/haproxy/certs/authentik.bgalhardo.internal.pem
rc-service haproxy restart && lbu commit
```

## Rebuild from bare Alpine

1. Flash **Alpine armhf** (the ARMv6 build) to the SD card, boot, `setup-alpine`
   (hostname `hermes`, static `192.168.1.199/24` gw `.1`, no DHCP).
2. Copy `repositories` to `/etc/apk/`, `apk update`, then
   `apk add dnsmasq haproxy openssh openssl prometheus-node-exporter` (matches `world`).
3. Drop `custom.conf`, `haproxy.cfg`, `interfaces` into place.
4. Issue the HAProxy cert (above).
5. `rc-update add dnsmasq default; rc-update add haproxy default;
   rc-update add sshd default; rc-update add ntpd default;
   rc-update add crond default; rc-update add node-exporter default`
6. Start them, then `lbu commit`.

## Backup

`lbu commit` persists `/etc` into `mmcblk0p1/hermes.apkovl.tar.gz`. That
tarball carries private keys — **do not commit it to git**. Copy it to the
NAS as part of 3-2-1:

```sh
scp root@192.168.1.199:/media/mmcblk0p1/hermes.apkovl.tar.gz \
    <nas>/backups/hermes/hermes-$(date +%F).apkovl.tar.gz
```

