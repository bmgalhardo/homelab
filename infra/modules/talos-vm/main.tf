# Talos VMs on olympus. Used by infra/elysium/terraform and infra/gaia/terraform.

resource "proxmox_vm_qemu" "talos" {
  for_each           = var.nodes
  name               = each.key
  vmid               = each.value.vmid
  target_node        = each.value.node
  qemu_os            = "l26"
  agent              = 1
  start_at_node_boot = each.value.onboot
  power_state        = each.value.onboot ? "running" : "stopped"
  machine            = each.value.gpu == null ? null : "q35"
  memory             = each.value.memory
  balloon            = each.value.memory # = memory: stats reporting only, never shrinks
  scsihw             = "virtio-scsi-single"
  skip_ipv6          = true
  protection         = false
  tags               = var.tags

  boot = "order=scsi0;ide2"

  cpu {
    type    = "x86-64-v3"
    sockets = 1
    cores   = each.value.cores
  }

  dynamic "pci" {
    for_each = each.value.gpu == null ? [] : [each.value.gpu]
    content {
      id         = 0
      mapping_id = pci.value
      pcie       = true
    }
  }

  network {
    id       = 0
    bridge   = "vmbr0"
    firewall = true
    model    = "virtio"
    macaddr  = each.value.mac
  }

  disks {
    scsi {
      # System disk: Talos + EPHEMERAL (images, logs, emptyDirs). Nothing
      # persistent lives here — EPHEMERAL is wiped by a node reset.
      scsi0 {
        disk {
          size       = each.value.disk_size
          storage    = "local-lvm"
          iothread   = true
          discard    = true
          emulatessd = true
          replicate  = true
        }
      }
      # Data disk: the Talos `local-path` user volume, i.e. every PVC.
      # A SEPARATE disk on purpose:
      #  - EPHEMERAL can then own the whole system disk; when both shared one
      #    disk the user volume sat immediately after EPHEMERAL and physically
      #    blocked it from ever growing (the DiskPressure incident).
      #  - Proxmox can snapshot/back it up as its own volume.
      #  - A node reset wipes EPHEMERAL and leaves this disk alone, so PVCs
      #    survive a Talos rebuild.
      dynamic "scsi1" {
        for_each = each.value.data_disk_size == null ? [] : [each.value.data_disk_size]
        content {
          disk {
            size       = scsi1.value
            storage    = "local-lvm"
            iothread   = true
            discard    = true
            emulatessd = true
            replicate  = true
          }
        }
      }
    }
    ide {
      ide2 {
        cdrom {
          iso = coalesce(each.value.iso, var.iso)
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      network, # MAC churn on telmate refresh
      # PVE stores startup defaults (order/up/down = -1) alongside onboot. The
      # provider surfaces them as a block this config doesn't manage, so every
      # plan proposed deleting it. Ignored rather than declared: the goal is a
      # plan that is empty when nothing changed, so a real diff is worth reading.
      startup_shutdown,
      # reads back false on VMs not cloned from a template; a diff forces replacement.
      full_clone,
      # onboot=false VMs are powered by hand after create.
      power_state,
    ]
  }
}
