# PROXMOX
variable "proxmox_host" {}
variable "proxmox_token_id" {}
variable "proxmox_token_secret" {}

variable "node_data" {
  description = "A map of the vms to create"
  type = map(object({
    vmid       = optional(number)
    node       = string
    memory     = number
    cores      = number
    disk_size  = string
    ip         = optional(string)
    mac        = optional(string)
    tags       = optional(string)
  }))
}
