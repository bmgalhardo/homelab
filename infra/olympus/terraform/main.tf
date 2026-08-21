locals {
  ssh_pub_key = file("~/.ssh/id_ed25519.pub")
}

resource "proxmox_vm_qemu" "node" {
  for_each           = var.node_data
  name               = each.key
  vmid               = each.value.vmid
  target_node        = each.value.node
  clone              = "alpine-template"
  full_clone         = true 
  os_type            = "cloud-init"
  qemu_os            = "l26"
  agent              = 1
  start_at_node_boot = true
  boot               = "order=virtio0"
  memory             = each.value.memory
  scsihw             = "virtio-scsi-single"
  skip_ipv6          = true
  protection         = false
  tags               = each.value.tags
  cpu {
    type      = "x86-64-v2-AES"
    sockets   = 1
    cores     = each.value.cores
  }
  network {
    id        = 0
    bridge    = "vmbr0"
    firewall  = true
    link_down = false
    model     = "virtio"
    macaddr   = each.value.mac
  }
  disks {
    virtio {
      virtio0 {
        disk {
          storage  = "local-lvm"
          size     = each.value.disk_size
        }
      }
    }
    ide {
      ide3 {
        cloudinit {
          storage = "local-lvm"
        }
      }
    }
  }
  # cloud-init user-data
  ciuser     = "root"
  cipassword = "root"
  ipconfig0  = "ip=dhcp"
  sshkeys   = local.ssh_pub_key
}
