# elysium — Talos VMs. Terraform only builds the compute; Omni owns the
# cluster (see ../omni/). VMs boot the Omni ISO, register via SideroLink,
# then the Omni ClusterTemplate assigns + configures them.

resource "proxmox_vm_qemu" "talos" {
  for_each           = var.node_data
  name               = each.key
  vmid               = each.value.vmid
  target_node        = each.value.node
  qemu_os            = "l26"
  agent              = 1
  start_at_node_boot = true
  power_state = "running"
  memory      = each.value.memory
  scsihw      = "virtio-scsi-single"
  skip_ipv6   = true
  protection  = false
  tags        = "k8s"

  boot = "order=scsi0;ide2"

  cpu {
    type    = "x86-64-v2-AES"
    sockets = 1
    cores   = each.value.cores
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
          size     = each.value.disk_size
          storage  = "local-lvm"
          iothread = true
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
          iso = var.omni_iso
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
    ]
  }
}

# virtiofs — telmate can't express it. Set by hand after create, then a
# full stop+start (not just `qm set`) for it to actually attach — see
# ../README.md step 3.

output "next" {
  value = <<-EOT
    VMs created. Now:
      1. virtiofs on elysium-hades (telmate can't) — on the Hades PVE host:
         for m in 0:series 1:movies 2:downloads 3:photos; do
           qm set 1102 -virtiofs$${m%%:*} dirid=$${m##*:},cache=auto
         done
      2. Start the VMs; they register in Omni as available machines.
      3. Wire their UUIDs into ../omni/cluster.yaml, then:
         omnictl cluster template sync -f ../omni/cluster.yaml
  EOT
}
