# Internal root CA (public)

`root-ca.crt` — `CN=Root CA bgalhardo.internal`, self-signed, valid
**2025-07-01 → 2035-06-29**.

```
SHA256  2E:C2:52:34:5D:A5:B8:08:91:64:73:B6:BF:D9:EF:F4:AA:7D:8A:2B:A5:BB:EA:3D:64:51:BC:E9:E1:F5:D6:13
serial  0AA2538DB907B40AE55CE86490E40660AE1D66C9
```

Public certificate — safe to commit and ship anywhere. It lets a machine
verify Vault; it never authenticates a machine *to* Vault (that is AppRole).

Distribute it from this file at build time, not by fetching it from Vault. If
you do fetch it over an untrusted channel, verify the SHA256 above first.

## Installing it

**Alpine / Debian (system-wide):**
```sh
cp root-ca.crt /usr/local/share/ca-certificates/bgalhardo-root.crt
update-ca-certificates
# Alpine diskless (hermes) only — otherwise it is lost on reboot:
lbu commit
```

**Vault Agent** needs only the file, not the system store — `ca_cert` in
`config.hcl` points at `./vault-agent/ca.crt`. Ship this file to that path.

**Talos** takes it via machine config:
`infra/elysium/omni/patches/trusted-ca.yaml` and `omni/media-preset.yaml`.

**elysium's VSO** gets it as the `vault-ca` Secret from
`infra/vault/k8s-auth-bootstrap.sh`.

## Verify from any machine

```sh
curl -s --cacert root-ca.crt https://vault.bgalhardo.internal/v1/sys/health
```
Exit code 0 means the chain built from this anchor alone. Vault serves
leaf + `Intermediate CA bgalhardo.internal [infra]`, so the root is
sufficient — do not also ship the intermediate.
