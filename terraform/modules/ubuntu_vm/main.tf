# An Ubuntu VM made from the pinned cloud image: cloud-init sets the user, the key, the DNS and
# a static address per NIC. Everything goes through the Proxmox API. The guest agent and the
# rest come later from Ansible (role guest_base). Every VM of the lab that is not adopted from
# an existing install is one of these (the vault VM, in the secrets enclave, has its own).

resource "proxmox_virtual_environment_vm" "this" {
  node_name     = var.node
  vm_id         = var.vm_id
  name          = var.name
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
    cores   = var.cores
    type    = var.cpu_type
  }

  memory {
    dedicated = var.memory_mb
    floating  = var.memory_mb
  }

  disk {
    datastore_id = var.datastore
    interface    = "scsi0"
    import_from  = var.image_id
    size         = var.disk_gb
    iothread     = true
    discard      = "on"
  }

  # net0 first: the lab network and the default route. A second NIC is on the same bridge
  # (the home /24 shares the L2 segment).
  dynamic "network_device" {
    for_each = var.nics
    content {
      bridge      = "vmbr0"
      model       = "virtio"
      mac_address = network_device.value.mac
      firewall    = true
    }
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.datastore

    user_account {
      username = "ubuntu"
      keys     = [var.ssh_public_key]
    }

    dns {
      # Set here, not taken from the host's resolv.conf, which changes at boot (NetBird
      # rewrites it). Any change to this config makes cloud-init treat the VM as new.
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    # ipconfigN goes to netN, in the same order.
    dynamic "ip_config" {
      for_each = var.nics
      content {
        ipv4 {
          address = ip_config.value.address
          gateway = ip_config.value.gateway
        }
      }
    }
  }

  startup {
    order    = var.startup_order
    up_delay = 15
  }

  lifecycle {
    # plan-guard refuses every delete and replace as well. To retire a VM on purpose, drop it
    # from Terraform with a removed block, then delete it in Proxmox.
    prevent_destroy = true
    # Two NICs with one MAC: cloud-init refuses to configure either ("duplicate mac found"),
    # and the VM boots with no network at all.
    precondition {
      condition     = length(distinct([for n in var.nics : lower(n.mac)])) == length(var.nics)
      error_message = "The VM's NICs need different MACs (mac and home_mac in the site dict)."
    }
    # import_from only matters when the disk is created. Changing the image later must not
    # replace a running VM's disk.
    ignore_changes = [disk[0].import_from]
  }
}
