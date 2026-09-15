# Internal root CA (public)

`root-ca.crt` — `CN=Root CA bgalhardo.internal`, self-signed, valid
**2025-07-01 → 2035-06-29**.

```
SHA256  2E:C2:52:34:5D:A5:B8:08:91:64:73:B6:BF:D9:EF:F4:AA:7D:8A:2B:A5:BB:EA:3D:64:51:BC:E9:E1:F5:D6:13
serial  0AA2538DB907B40AE55CE86490E40660AE1D66C9
```

## This file is not a secret

It is a **public key certificate**. Committing it is correct and
deliberate — it is not covered by the "no sensitive data in git" rule in
CLAUDE.md, which is about the CA *private key* (in Vault, `pki_root`),
AppRole `secret_id`s, and `.env` values.

## Why it is committed rather than fetched

The CA answers "is this really Vault?", so fetching it *from* Vault over a
connection you cannot yet verify is the wrong shape: a MITM would hand you
their CA and own that machine's trust until 2035. The CA is also static —
it changes once a decade — so it belongs in the provisioning artifact, not
in a runtime code path.

Distribute it **out-of-band, at build time**. If you ever do fetch it over
an untrusted channel, verify the SHA256 above before installing it; then
the transport does not matter.

## Direction of trust

| | |
|---|---|
| machine → Vault (**auth**) | AppRole `role_id` + `secret_id` — the secret |
| Vault → machine (**trust**) | this CA — public |

The CA never authenticates a machine to Vault. Do not conflate them.

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

**Talos** takes it via machine config, already wired:
`infra/elysium/omni/patches/trusted-ca.yaml` and `omni/media-preset.yaml`
(both verified identical to this file).

## Verify from any machine

```sh
curl -s --cacert root-ca.crt https://vault.bgalhardo.internal/v1/sys/health
```
Exit code 0 means the chain built from this anchor alone. Vault serves
leaf + `Intermediate CA bgalhardo.internal [infra]`, so the root is
sufficient — do not also ship the intermediate.
