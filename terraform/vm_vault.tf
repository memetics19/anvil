# The Vault VM: Ubuntu 24.04 cloud image, cloud-init for user, key and static address.
# Everything goes through the Proxmox API (no SSH): the image is downloaded into local's
# import store (enabled by the pve_host role, tag storage). The guest agent is installed
# afterwards by the guest_base role (make vms), then the VM is restarted once. It will hold secrets, so it is never destroyed by Terraform.
# Addresses and VMID are site values (var.site_json); the public key is read at plan
# time from var.ssh_public_key_path and is not committed.

# Bumping the image: the URL and checksum are pinned to one release. Changing them makes
# the provider replace this download (plan-guard rejects the delete). Do not edit it in
# place. Either add a new pinned download_file resource (new name, new file_name) for
# new VMs, or `terraform state rm` this one first and then change it, so no replace
# is planned. The vault VM never re-imports (see ignore_changes below).
resource "proxmox_virtual_environment_download_file" "noble_cloudimg" {
  node_name           = var.node_name
  datastore_id        = "local"
  content_type        = "import"
  file_name           = "ubuntu-24.04-server-cloudimg-amd64-20261017.qcow2"
  url                 = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
  checksum            = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = false
}

resource "proxmox_virtual_environment_vm" "vault" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.vault.vmid)
  name          = "vault"
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
    dedicated = 1024
    floating  = 1024
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg.id
    size         = nonsensitive(try(local.site.hosts.vault.disk_gb, 10))
    iothread     = true
    discard      = "on"
  }

  # net0: the first NIC, on the lab network. Kept while the VM moves into the secrets
  # enclave; site.hosts.vault.lab_nic_retired = true takes its link down (README, Vault).
  network_device {
    bridge       = "vmbr0"
    model        = "virtio"
    mac_address  = nonsensitive(local.site.hosts.vault.mac)
    firewall     = true
    disconnected = try(local.site.hosts.vault.lab_nic_retired, false)
  }

  # net1: the secrets enclave (sdn.tf). Its address and the default route are set in the
  # guest by Ansible (guest_base, enclave mode), not by cloud-init.
  network_device {
    bridge      = proxmox_sdn_vnet.secrets.id
    model       = "virtio"
    mac_address = nonsensitive(local.site.hosts.vault.enclave_mac)
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
      # Set here, not taken from the host's resolv.conf, which changes at boot (NetBird
      # rewrites it). Any change to this config makes cloud-init treat the VM as new.
      domain  = local.site.domain
      servers = local.site.guest_dns
    }

    ip_config {
      ipv4 {
        # The lab address it was created with (site.hosts.vault.ip is its enclave address).
        address = "${try(local.site.hosts.vault.lab_ip, local.site.hosts.vault.ip)}/${split("/", local.site.lan_cidr)[1]}"
        gateway = local.site.pve.gateway_alias_ip
      }
    }
  }

  # Start before the other VMs.
  startup {
    order    = 1
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # import_from only matters when the disk is created. Ignoring it keeps a later image
    # bump from planning a change to this VM's disk.
    ignore_changes = [disk[0].import_from]
  }
}
