# The Vaultwarden VM, in the secrets enclave (sdn.tf, vnet secrets): no internet. Same
# pattern as the vault VM (vm_vault.tf): Ubuntu 24.04 cloud image imported through the
# Proxmox API, cloud-init for user, key and static address. One NIC, on the enclave; its
# gateway is the Proxmox host, which forwards only what the pve_enclave role allows (DNS to
# Pi-hole and SMTP to the relay; apt and NTP go to the host itself).
# The vendor-data snippet (role pve_enclave, make enclave ARGS="--tags cloudinit") points apt
# at the host's apt cache and time at the host's chrony from the first boot, and installs
# the guest agent. It holds the password vault, so it is never destroyed by Terraform
# (plan-guard protects its disk too). Address and VMID are site values
# (site.hosts.vaultwarden.{ip,vmid}); DNS is Pi-hole (site.hosts.apps.ip).

resource "proxmox_virtual_environment_vm" "vaultwarden" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.vaultwarden.vmid)
  name          = "vaultwarden"
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
    dedicated = 512
    floating  = 512
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg.id
    size         = nonsensitive(try(local.site.hosts.vaultwarden.disk_gb, 8))
    iothread     = true
    discard      = "on"
  }

  network_device {
    bridge   = proxmox_sdn_vnet.secrets.id
    model    = "virtio"
    firewall = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id        = "local-lvm"
    vendor_data_file_id = "local:snippets/enclave-vendor.yaml"

    user_account {
      username = "ubuntu"
      keys     = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
    }

    dns {
      servers = [local.site.hosts.apps.ip]
    }

    ip_config {
      ipv4 {
        address = "${local.site.hosts.vaultwarden.ip}/${split("/", local.site.sdn.enclave.subnet)[1]}"
        gateway = local.site.sdn.enclave.gateway
      }
    }
  }

  # After the vault VM and the apps VM (Pi-hole).
  startup {
    order    = 2
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # import_from only matters when the disk is created (see vm_vault.tf).
    ignore_changes = [disk[0].import_from]
  }
}
