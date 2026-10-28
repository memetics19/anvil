# The apps VM: small always-on services shared on one VM to save memory (Pi-hole now,
# Vaultwarden later). Same pattern as the vault VM (vm_vault.tf): Ubuntu 24.04 cloud
# image imported through the Proxmox API, cloud-init for user, key and static addresses,
# guest agent installed afterwards by guest_base (make vms). It will hold Vaultwarden's
# data, so it is never destroyed by Terraform (plan-guard protects its disk too).
#
# Two NICs on vmbr0, both addressed by cloud-init (ipconfig0/ipconfig1): net0 on the lab
# network with the default route via the lab gateway like every guest, net1 on the home
# network with no gateway, so home clients reach Pi-hole directly on their own subnet.
# Proxmox cloud-init takes one address per NIC, so two NICs keep the whole network
# config in cloud-init (guest_base leaves the netplan alone, as on the vault VM).
# Addresses, MACs and VMID are site values (site.hosts.apps.{ip,home_ip,mac,home_mac,vmid}).

resource "proxmox_virtual_environment_vm" "apps" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.apps.vmid)
  name          = "apps"
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
    type    = "host"
  }

  memory {
    dedicated = 1536
    floating  = 1536
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg.id
    size         = nonsensitive(try(local.site.hosts.apps.disk_gb, 16))
    iothread     = true
    discard      = "on"
  }

  # net0: lab network. MACs are pinned from site (the router's DHCP reservation for the
  # home address is made by MAC).
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.site.hosts.apps.mac)
    firewall    = true
  }

  # net1: home network (same bridge; the home /24 shares the L2 segment).
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.site.hosts.apps.home_mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = "local-lvm"

    user_account {
      username = "ubuntu"
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }

    dns {
      servers = local.site.guest_dns
    }

    # ipconfig0 -> net0 (lab, default route).
    ip_config {
      ipv4 {
        address = "${local.site.hosts.apps.ip}/${split("/", local.site.lan_cidr)[1]}"
        gateway = local.site.pve.gateway_alias_ip
      }
    }

    # ipconfig1 -> net1 (home, no gateway).
    ip_config {
      ipv4 {
        address = "${local.site.hosts.apps.home_ip}/${local.site.pve.uplink_prefix}"
      }
    }
  }

  # DNS for the whole home: start with the first group.
  startup {
    order    = 1
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # Two NICs with one MAC: cloud-init refuses to configure either ("duplicate mac found"),
    # and the VM boots with no network at all.
    precondition {
      condition     = lower(local.site.hosts.apps.mac) != lower(local.site.hosts.apps.home_mac)
      error_message = "The VM's two NICs need different MACs (mac and home_mac in the site dict)."
    }
    # import_from only matters when the disk is created (see vm_vault.tf).
    ignore_changes = [disk[0].import_from]
  }
}
