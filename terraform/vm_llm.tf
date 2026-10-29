# The LLM VM: a local language model (Ollama) with a chat UI (Open WebUI), on the second
# Proxmox node (site.hosts.llm.node). Created only when site.hosts.llm exists.
#
# One NIC on the lab network with the default route: the gateway proxies llm.<domain> to it,
# Pulse reaches it, and it has internet to pull the model. No home NIC (nothing on the home
# network talks to it directly). CPU inference only; these hosts have no GPU.
# Its disk is on that node's data pool (site.hosts.llm.datastore, default vmdata). It holds
# only the model cache and chat history, both replaceable, so Terraform may destroy it.

locals {
  llm      = try(local.site.hosts.llm, null)
  llm_node = try(local.site.hosts.llm.node, var.node_name)
}

# The same pinned image as the other VMs, downloaded to the llm node.
resource "proxmox_virtual_environment_download_file" "noble_cloudimg_llm" {
  count               = local.llm == null ? 0 : 1
  node_name           = local.llm_node
  datastore_id        = "local"
  content_type        = "import"
  file_name           = "ubuntu-24.04-server-cloudimg-amd64-20261017.qcow2"
  url                 = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
  checksum            = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = false
}

resource "proxmox_virtual_environment_vm" "llm" {
  count         = local.llm == null ? 0 : 1
  node_name     = local.llm_node
  vm_id         = nonsensitive(local.llm.vmid)
  name          = "llm"
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
    cores   = nonsensitive(try(local.llm.cores, 4))
    type    = "host"
  }

  # The model (Hermes 3 8B, Q4, about 5 GB) plus Open WebUI and the OS. Modest on purpose.
  memory {
    dedicated = nonsensitive(try(local.llm.memory_mb, 16384))
    floating  = nonsensitive(try(local.llm.memory_mb, 16384))
  }

  disk {
    datastore_id = nonsensitive(try(local.llm.datastore, "vmdata"))
    interface    = "scsi0"
    import_from  = proxmox_virtual_environment_download_file.noble_cloudimg_llm[0].id
    size         = nonsensitive(try(local.llm.disk_gb, 40))
    iothread     = true
    discard      = "on"
  }

  # net0: lab network, default route.
  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.llm.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = nonsensitive(try(local.llm.datastore, "vmdata"))

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
        address = "${local.llm.ip}/${split("/", local.site.lan_cidr)[1]}"
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
