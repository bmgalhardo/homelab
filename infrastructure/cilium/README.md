# Cillium

## Talos
If using this for a talos cluster, since this is required for node communication, this service will be 
installed during provisioning (only on controlplane nodes). Failing to do so will leave the cluster without a cni and will reboot in 10m. More on this
[here](https://www.talos.dev/v1.6/kubernetes-guides/network/deploying-cilium/). Since the collection of manifests are applied everyime at boot. Any change to
these resources (or deletes) are not persistent.
