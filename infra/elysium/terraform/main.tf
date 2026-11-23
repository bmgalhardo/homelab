# elysium — Talos VMs. Terraform only builds the compute; Omni owns the
# cluster (see ../omni/). VMs boot the Omni ISO, register via SideroLink,
# then the Omni ClusterTemplate assigns + configures them.

module "talos" {
  source = "../../modules/talos-vm"
  nodes  = var.node_data
  iso    = var.omni_iso
}

moved {
  from = proxmox_vm_qemu.talos
  to   = module.talos.proxmox_vm_qemu.talos
}

# virtiofs — telmate can't express it. Set by hand after create, then a
# full stop+start (not just `qm set`) for it to actually attach — see
# ../README.md step 3.

output "next" {
  value = join("\n", concat(
    [
      "Only for VMs this apply CREATED (updates keep their virtiofs):",
      "  1. virtiofs (telmate can't), on the PVE host, then stop+start the VM:",
    ],
    [for name, n in var.node_data :
      "     ${name}: qm config ${n.vmid} | grep -q virtiofs || for m in ${join(" ", [for i, d in n.virtiofs : "${i}:${d}"])}; do qm set ${n.vmid} -virtiofs$${m%%:*} dirid=$${m##*:},cache=auto; done"
    if length(n.virtiofs) > 0],
    [
      "  2. Start the VM; it registers in Omni (labelled via the ISO preset or by hand).",
      "  3. omnictl cluster template sync -f ../omni/cluster.yaml",
    ],
  ))
}
