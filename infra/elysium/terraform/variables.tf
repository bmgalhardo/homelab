variable "omni_iso" {
  description = "Proxmox volid of the Omni installer ISO, e.g. local:iso/omni-xxxx-amd64.iso"
  type        = string
}

variable "node_data" {
  description = "Talos VMs for the elysium cluster (schema: ../../modules/talos-vm/variables.tf)"
  type        = any
}
