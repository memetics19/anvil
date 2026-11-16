# The Wazuh VM: the security monitor (role wazuh_server) on the second Proxmox node
# (site.hosts.wazuh.node). Created only when site.hosts.wazuh exists.
#
# One NIC on the lab network: every agent reports to it there, and the gateway proxies the
# dashboard. Its disk holds the alert history (indexer data): replaceable, but losing it loses
# the past, so cores, memory and disk are sized for a year of a small lab.

locals {
  wazuh      = try(local.site.hosts.wazuh, null)
  wazuh_node = try(local.site.hosts.wazuh.node, var.node_name)
}

resource "proxmox_virtual_environment_vm" "wazuh" {
  count         = local.wazuh == null ? 0 : 1
  node_name     = local.wazuh_node
  vm_id         = nonsensitive(local.wazuh.vmid)
  name          = "wazuh"
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
    cores   = nonsensitive(try(local.wazuh.cores, 4))
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = nonsensitive(try(local.wazuh.memory_mb, 8192))
    floating  = nonsensitive(try(local.wazuh.memory_mb, 8192))
  }

  disk {
    datastore_id = nonsensitive(try(local.wazuh.datastore, "vmdata"))
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg[local.wazuh_node].id
    size         = nonsensitive(try(local.wazuh.disk_gb, 80))
    iothread     = true
    discard      = "on"
  }

  # net0: lab network, default route.
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.wazuh.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = nonsensitive(try(local.wazuh.datastore, "vmdata"))

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
        address = "${local.wazuh.ip}/${split("/", local.site.lan_cidr)[1]}"
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
