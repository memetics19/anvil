# The monitoring VM: metrics, dashboards and alerts (role monitoring, docs/monitoring.md) on
# the second Proxmox node (site.hosts.monitoring.node). Created only when
# site.hosts.monitoring exists.
#
# One NIC on the lab network: it scrapes every host there, and the gateway proxies Grafana.
# Its disk holds 90 days of metrics: replaceable, but losing it loses the history.

locals {
  monitoring      = try(local.site.hosts.monitoring, null)
  monitoring_node = try(local.site.hosts.monitoring.node, var.node_name)
}

# The same pinned image as noble_cloudimg (vm_vault.tf), downloaded to the monitoring node:
# a cloud image in a node's local store can only be imported on that node.
resource "proxmox_virtual_environment_download_file" "noble_cloudimg_monitoring" {
  count               = local.monitoring == null ? 0 : 1
  node_name           = local.monitoring_node
  datastore_id        = "local"
  content_type        = "import"
  file_name           = "ubuntu-24.04-server-cloudimg-amd64-20261017.qcow2"
  url                 = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
  checksum            = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = false
}

resource "proxmox_virtual_environment_vm" "monitoring" {
  count         = local.monitoring == null ? 0 : 1
  node_name     = local.monitoring_node
  vm_id         = nonsensitive(local.monitoring.vmid)
  name          = "monitoring"
  on_boot       = true
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change.
  reboot_after_update = false

  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    sockets = 1
    cores   = nonsensitive(try(local.monitoring.cores, 2))
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = nonsensitive(try(local.monitoring.memory_mb, 4096))
    floating  = nonsensitive(try(local.monitoring.memory_mb, 4096))
  }

  disk {
    datastore_id = nonsensitive(try(local.monitoring.datastore, "vmdata"))
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg_monitoring[0].id
    size         = nonsensitive(try(local.monitoring.disk_gb, 60))
    iothread     = true
    discard      = "on"
  }

  # net0: lab network, default route.
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.monitoring.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = nonsensitive(try(local.monitoring.datastore, "vmdata"))

    user_account {
      username = "ubuntu"
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }

    dns {
      domain  = local.site.domain
      servers = local.site.guest_dns
    }

    ip_config {
      ipv4 {
        address = "${local.monitoring.ip}/${split("/", local.site.lan_cidr)[1]}"
        gateway = local.site.pve.gateway_alias_ip
      }
    }
  }

  startup {
    order    = 2
    up_delay = 15
  }

  lifecycle {
    ignore_changes = [disk[0].import_from]
  }
}
