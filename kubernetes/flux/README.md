# Flux — GitOps for the elysium cluster

Flux reconciles everything under `kubernetes/` after the cluster is up.
Only what is **committed** is reconciled.

## Layout

```
kubernetes/
├── flux/clusters/elysium/    Flux entrypoint: flux-system + one root Kustomization per tier
├── 10-infra-base/            cert-manager, VSO, MetalLB, nginx-gateway-fabric,
│                             Gateway API CRDs, local-path        (HelmReleases + CRDs)
├── 20-infra-wiring/          Gateways, cert Issuers, MetalLB pool,
│                             Hades virtiofs PVs, external-dns
└── 30-apps/                  the workloads (system/, immich/, _parked/)
```

Reconcile order, via `dependsOn`: `10-infra-base` → `20-infra-wiring` →
`30-apps`. Directory names and Kustomization names are identical, so
`flux get kustomizations` maps 1:1 onto the tree.

**Which tier does a thing go in?** If tier 1 has to install its API before
the object can even be applied, it belongs in tier 2. Every custom resource
in `20-infra-wiring` (`Issuer`, `Gateway`, `IPAddressPool`,
`VaultStaticSecret`) has its CRD installed by tier 1 — that dependency *is*
the reason for the split, not a tidiness preference.

Tier 1 is reconciled with `wait: true`: Flux holds tier 2 until every
object in tier 1 is actually healthy. A `HelmRelease` is only a *request* —
kustomize-controller applies it and reports success immediately, while
helm-controller installs the chart asynchronously afterwards. Without the
gate, tier 2's custom resources would race the CRDs into existence.

## Bootstrap

```sh
export GITHUB_TOKEN=...   # classic PAT, repo scope; or --token-auth for a deploy key
flux bootstrap git \
 --url=ssh://git@github.com/bmgalhardo/homelab.git \
 --branch=main \
 --path=kubernetes/flux/clusters/elysium
```

This installs the controllers, adds a deploy key to the GitHub repo, and
**commits a `flux-system/` dir** next to this file

Watching it:
```sh
flux get kustomizations --watch
flux get helmreleases -A
```

Note that the vault script needs to be run in order to vso can retrieve the secrets.
```sh
VAULT_ADDR=https://vault.bgalhardo.internal \
VAULT_TOKEN=... \
./infra/olympus/services/vault/bootstrap-k8s-auth.sh
```