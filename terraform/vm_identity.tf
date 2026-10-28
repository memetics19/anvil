# The identity VM: single sign-on (Authentik) and the LDAP directory for the lab, on the
# second Proxmox node of the cluster (site.hosts.identity.node). Created only when
# site.hosts.identity exists.
#
# Same pattern as the apps VM (vm_apps.tf): the Ubuntu 24.04 cloud image imported through
# the Proxmox API, cloud-init for user, key and both addresses, two NICs on vmbr0: net0 on
# the lab network with the default route, net1 on the home network with no gateway, so the
# gateway, the operator's devices and the lab VMs all reach it on their own subnet.
# Its disk is on that node's data pool (site.hosts.identity.datastore, default vmdata).
# It holds the user directory, so it is never destroyed by Terraform.

locals {
  identity      = try(local.site.hosts.identity, null)
  identity_node = try(local.site.hosts.identity.node, var.node_name)
}

# The same pinned image as noble_cloudimg (vm_vault.tf), downloaded to the identity node:
# a cloud image in a node's local store can only be imported on that node.
resource "proxmox_virtual_environment_download_file" "noble_cloudimg_identity" {
  count               = local.identity == null ? 0 : 1
  node_name           = local.identity_node
  datastore_id        = "local"
  content_type        = "import"
  file_name           = "ubuntu-24.04-server-cloudimg-amd64-20261017.qcow2"
  url                 = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
  checksum            = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = false
}

resource "proxmox_virtual_environment_vm" "identity" {
  count         = local.identity == null ? 0 : 1
  node_name     = local.identity_node
  vm_id         = nonsensitive(local.identity.vmid)
  name          = "identity"
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
    cores   = nonsensitive(try(local.identity.cores, 2))
    type    = "host"
  }

  # Authentik (server and worker), its Postgres and Redis.
  memory {
    dedicated = nonsensitive(try(local.identity.memory_mb, 3072))
    floating  = nonsensitive(try(local.identity.memory_mb, 3072))
  }

  disk {
    datastore_id = nonsensitive(try(local.identity.datastore, "vmdata"))
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg_identity[0].id
    size         = nonsensitive(try(local.identity.disk_gb, 32))
    iothread     = true
    discard      = "on"
  }

  # net0: lab network.
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.identity.mac)
    firewall    = true
  }

  # net1: home network (same bridge, the home /24 shares the L2 segment).
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.identity.home_mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = nonsensitive(try(local.identity.datastore, "vmdata"))

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
        address = "${local.identity.ip}/${split("/", local.site.lan_cidr)[1]}"
        gateway = local.site.pve.gateway_alias_ip
      }
    }

    # ipconfig1 -> net1 (home, no gateway).
    ip_config {
      ipv4 {
        address = "${local.identity.home_ip}/${local.site.pve.uplink_prefix}"
      }
    }
  }

  startup {
    order    = 1
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # Two NICs with one MAC: cloud-init refuses to configure either ("duplicate mac found"),
    # and the VM boots with no network at all.
    precondition {
      condition     = lower(local.identity.mac) != lower(local.identity.home_mac)
      error_message = "The VM's two NICs need different MACs (mac and home_mac in the site dict)."
    }
    # import_from only matters when the disk is created (see vm_vault.tf).
    ignore_changes = [disk[0].import_from]
  }
}
