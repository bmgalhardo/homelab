# tftp-server

Not a Docker service — runs natively on Alpine. There's nothing to
`docker compose up` here; this README is the setup procedure.

## Setup

```sh
# Install the TFTP daemon
apk add tftp-hpa

# Enable + start it
rc-update add in.tftpd default
rc-service in.tftpd start

# Deploy the PXE boot binary
mkdir -p /var/tftpboot
cp undionly.kpxe /var/tftpboot/
```

`undionly.kpxe` comes from building iPXE
(`ipxe/src/bin/undionly.kpxe` in the [ipxe](https://github.com/ipxe/ipxe)
source tree) — it's a binary artifact, not checked into this repo.

## Verify

```sh
rc-service in.tftpd status
ls -la /var/tftpboot/
```

## Notes

- This VM is defined in `inventory/hosts.ini` as `tftp` (distinct from
  `netboot`, which is retired — see PKI notes in
  `.claude/context/network.md`).
- No secrets, no compose file, no `.env` — the whole service is this one
  binary plus the daemon.
