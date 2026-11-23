variable "iso" {
  description = "Default installer ISO (Proxmox volid) for nodes without their own"
  type        = string
}

variable "tags" {
  type    = string
  default = "k8s"
}

variable "nodes" {
  description = "Talos VMs, keyed by name"
  type = map(object({
    vmid      = number
    node      = string # proxmox node: apollo | hades
    mac       = string
    cores     = number
    memory    = number # MB
    disk_size = string # system disk (Talos + EPHEMERAL only), e.g. "40G"
    # Second disk backing the Talos `local-path` user volume — i.e. all PVCs.
    # Omit for nodes that run no workloads (the control plane).
    data_disk_size = optional(string)
    # virtiofs directory mappings (PVE Datacenter -> Directory Mappings) to
    # attach as virtiofsN devices. telmate can't express these — set by
    # hand after create (README step 3), informational here only.
    virtiofs = optional(list(string), [])
    # PVE Resource Mapping id (Datacenter -> Resource Mappings -> PCI) to pass
    # through; switches the VM to q35.
    gpu = optional(string)
    # Overrides var.iso for this node.
    iso = optional(string)
    # false: not started at host boot, created stopped, powered by hand.
    onboot = optional(bool, true)
  }))
}
