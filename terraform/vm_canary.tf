# The canary VM: a tripwire (OpenCanary, role canary) on the second Proxmox node
# (site.hosts.canary.node). Created only when site.hosts.canary exists.
#
# Nothing legitimate ever talks to it, so any connection, login attempt or port scan is an
# alarm. One NIC on the lab network, where an intruder would look. Small, and it holds nothing:
# Terraform may destroy and recreate it.

locals {
  canary      = try(local.site.hosts.canary, null)
  canary_node = try(local.site.hosts.canary.node, var.node_name)
}

resource "proxmox_virtual_environment_vm" "canary" {
  count         = local.canary == null ? 0 : 1
  node_name     = local.canary_node
  vm_id         = nonsensitive(local.canary.vmid)
  name          = "canary"
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
    cores   = 1
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = nonsensitive(try(local.canary.memory_mb, 1024))
    floating  = nonsensitive(try(local.canary.memory_mb, 1024))
  }

  disk {
    datastore_id = nonsensitive(try(local.canary.datastore, "vmdata"))
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg[local.canary_node].id
    size         = nonsensitive(try(local.canary.disk_gb, 12))
    iothread     = true
    discard      = "on"
  }

  # net0: lab network, default route.
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.canary.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = nonsensitive(try(local.canary.datastore, "vmdata"))

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
        address = "${local.canary.ip}/${split("/", local.site.lan_cidr)[1]}"
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
