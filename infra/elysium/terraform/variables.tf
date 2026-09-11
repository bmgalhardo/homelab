variable "proxmox_host" {}
variable "proxmox_token_id" {}
variable "proxmox_token_secret" {}

variable "omni_iso" {
  description = "Proxmox volid of the Omni installer ISO, e.g. local:iso/omni-xxxx-amd64.iso"
  type        = string
}

variable "node_data" {
  description = "Talos VMs for the elysium cluster"
  type = map(object({
    vmid      = number
    node      = string # proxmox node: apollo | hades
    mac       = string
    cores     = number
    memory    = number # MB
    disk_size = string # e.g. "40G"
    # virtiofs directory mappings (PVE Datacenter -> Directory Mappings) to
    # attach as virtiofsN devices. telmate can't express these — set by
    # hand after create (README step 3), informational here only.
    virtiofs = optional(list(string), [])
  }))
}
