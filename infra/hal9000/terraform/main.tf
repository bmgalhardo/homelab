resource "proxmox_vm_qemu" "talos_node" {
  for_each    = var.node_data
  name        = each.key
  vmid        = each.value.vmid
  target_node = each.value.node
  qemu_os     = "l26"
  agent       = 1
  onboot      = true
  memory      = each.value.memory
  scsihw      = "virtio-scsi-single"
  skip_ipv6   = true
  protection  = false
  tags        = "k8s"
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
    scsi {
      scsi0 {
        disk {
          size     = each.value.disk_size
          storage  = "local-lvm"
          iothread = true
        }
      }
      dynamic "scsi1" {
        for_each = length(each.value.passthrough) > 0 ? [1] : []
        content {
          passthrough {
            backup = false
            replicate = false
            file   = each.value.passthrough[0]
          }
        }
      }
    }
  }
}
