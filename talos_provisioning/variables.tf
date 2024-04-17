# PROXMOX
variable "proxmox_host" {}
variable "proxmox_token_id" {}
variable "proxmox_token_secret" {}

# TALOS
variable "talos_cluster_name" {
  description = "A name to provide for the Talos cluster"
  type        = string
  default     = "hal9000"
}

variable "talos_vip_ip" {
  description = "The ip address for the Talos cluster endpoint"
  type        = string
  default     = "192.168.1.180"
}

variable "talos_version" {
  description = "The Talos version to use"
  type        = string
}

variable "node_data" {
  description = "A map of Talos node data"
  type = map(object({
    machine_type      = string
    install_disk      = string
    static_ip_address = string
    schematic_id      = string
    memory            = number
    cores             = number
    disk_size         = number
    passthrough       = list(string)
  }))
}
