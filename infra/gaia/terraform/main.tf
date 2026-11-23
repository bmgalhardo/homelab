# gaia — single-node Talos VM. Configured by ../bootstrap.sh, not Omni.

module "talos" {
  source = "../../modules/talos-vm"
  iso    = "local:iso/gaia-1.14.1-ce4c98.iso"
  tags   = "k8s;infrastructure"
  nodes = {
    gaia = {
      vmid           = 1200
      node           = "apollo"
      mac            = "02:00:00:00:03:00"
      cores          = 2
      memory         = 4096
      disk_size      = "20G"
      data_disk_size = "30G"
    }
  }
}
