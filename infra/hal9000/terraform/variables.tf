# PROXMOX
variable "proxmox_host" {}
variable "proxmox_token_id" {}
variable "proxmox_token_secret" {}

variable "node_data" {
  description = "A map of Talos node data"
  type = map(object({
    vmid              = number
    node              = string
    mac               = string
    memory            = number
    cores             = number
    disk_size         = string
    passthrough       = list(string)
  }))
}
