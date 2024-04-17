locals {
  controlplane_ips = [for a in var.node_data : a.static_ip_address if a.machine_type == "controlplane"]
  worker_ips = [for a in var.node_data : a.static_ip_address if a.machine_type == "worker"]
}

#================================
# proxmox machines provisioning 
#================================

resource "proxmox_vm_qemu" "talos_node" {
  for_each    = var.node_data
  name        = each.key
  target_node = "prometheus"
  iso         = (
    "local:iso/talos-${var.talos_version}-metal-amd64-${substr(each.value.schematic_id, 0, 6)}.iso"
  )
  qemu_os     = "l26"
  agent       = 1
  onboot      = true
  memory      = each.value.memory
  cpu         = "x86-64-v2-AES"
  sockets     = 1
  cores       = each.value.cores
  scsihw      = "virtio-scsi-single"
  network {
    bridge    = "vmbr0"
    firewall  = true
    link_down = false
    model     = "virtio"
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
      dynamic "scsi2" {
        for_each = length(each.value.passthrough) > 1 ? [1] : []
        content {
          passthrough {
            backup = false
            replicate = false
            file   = each.value.passthrough[1]
          }
        }
      }
      dynamic "scsi3" {
        for_each =  length(each.value.passthrough) > 2 ? [1] : []
        content {
          passthrough {
            backup = false
            replicate = false
            file   = each.value.passthrough[2]
          }
        }
      }

    }
  }
}

#================================
# Talos bootstrap
#================================

resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "this" {
  for_each         = toset(["controlplane", "worker"])
  cluster_name     = var.talos_cluster_name
  cluster_endpoint = "https://${var.talos_vip_ip}:6443"
  machine_type     = each.key
  machine_secrets  = talos_machine_secrets.this.machine_secrets
  talos_version    = var.talos_version
}

data "talos_client_configuration" "this" {
  cluster_name         = var.talos_cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = local.controlplane_ips
}

resource "talos_machine_configuration_apply" "this" {
  depends_on                  = [proxmox_vm_qemu.talos_node]
  for_each                    = var.node_data
  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = (each.value.machine_type == "controlplane" ? 
    data.talos_machine_configuration.this["controlplane"].machine_configuration : 
    data.talos_machine_configuration.this["worker"].machine_configuration
  )
  node                        = proxmox_vm_qemu.talos_node[each.key].default_ipv4_address
  config_patches = flatten([
    [
      templatefile("${path.module}/templates/generic.yml.tmpl", {
        hostname          = each.key
        static_ip_address = each.value.static_ip_address
        install_disk      = each.value.install_disk
        schematic_id      = each.value.schematic_id
        talos_version     = var.talos_version 
      })
    ], 
    each.value.machine_type == "controlplane" ? [
      templatefile("${path.module}/templates/patch_vip.yml.tmpl", {
        vip_ip = var.talos_vip_ip
      }),
      file("${path.module}/templates/cilium_patch.yml")
    ] : [],
    each.key == "talos-worker-1" ? [file("${path.module}/templates/patch_mounts.yml")] : []
  ])
}

resource "talos_machine_bootstrap" "this" {
  depends_on = [talos_machine_configuration_apply.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_ips[0]
}

data "talos_cluster_kubeconfig" "this" {
  depends_on           = [talos_machine_bootstrap.this]

  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.controlplane_ips[0]
}

#data "talos_cluster_health" "this" {
#  depends_on = [data.talos_cluster_kubeconfig.this]
#
#  client_configuration = talos_machine_secrets.this.client_configuration
#  control_plane_nodes  = local.controlplane_ips
#  endpoints            = local.controlplane_ips
#  worker_nodes         = local.worker_ips
#  timeouts             = {
#    read = "5m"
#  }
#}

output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
