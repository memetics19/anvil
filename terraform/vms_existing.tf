# The three VMs that existed before this repo, adopted with import blocks (imports.tf).
# Every value mirrors `qm config` on the live box so the plan shows no changes.
# VMIDs and MACs are site values (var.site_json); sizes are literals. They are not
# secrets, only kept out of the repo, so they are unwrapped with nonsensitive(): marked
# sensitive, every adopted VM would plan a sensitivity-only in-place update.

locals {
  iso_ubuntu = "local:iso/ubuntu-24.04.3-live-server-amd64.iso"
}

resource "proxmox_virtual_environment_vm" "frigate" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.frigate.vmid)
  name          = "frigate"
  on_boot       = false
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change; restarts are
  # done by hand, one VM at a time.
  reboot_after_update = false
  boot_order          = ["scsi0", "ide2", "net0"]

  cpu {
    sockets = 2
    cores   = 2
    type    = "x86-64-v2-AES"
  }

  memory {
    dedicated = 4098
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 500
    iothread     = true
  }

  cdrom {
    interface = "ide2"
    file_id   = local.iso_ubuntu
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.site.hosts.frigate.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  startup {
    order    = 2
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # The provider reads the CD-ROM back only from the interface already in state
    # (default ide3), so after an import the ide2 ISO never appears in state and the
    # block would plan an update forever. Remove this when the ISO is detached (Task 6b).
    ignore_changes = [cdrom]
  }
}

resource "proxmox_virtual_environment_vm" "netbird" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.netbird.vmid)
  name          = "netbird"
  on_boot       = false
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change; restarts are
  # done by hand, one VM at a time.
  reboot_after_update = false
  boot_order          = ["scsi0", "ide2", "net0"]

  cpu {
    sockets = 1
    cores   = 1
    type    = "host"
  }

  memory {
    dedicated = 2048
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 42
    iothread     = true
  }

  cdrom {
    interface = "ide2"
    file_id   = local.iso_ubuntu
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.site.hosts.netbird.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  startup {
    order    = 2
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # The provider reads the CD-ROM back only from the interface already in state
    # (default ide3), so after an import the ide2 ISO never appears in state and the
    # block would plan an update forever. Remove this when the ISO is detached (Task 6b).
    ignore_changes = [cdrom]
  }
}

# ragnarok's disk holds the media library: the only data that must survive.
resource "proxmox_virtual_environment_vm" "ragnarok" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.ragnarok.vmid)
  name          = "ragnarok"
  on_boot       = false
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change; restarts are
  # done by hand, one VM at a time.
  reboot_after_update = false
  boot_order          = ["scsi0", "ide2", "net0"]

  cpu {
    sockets = 1
    cores   = 4
    type    = "host"
    limit   = 2
    units   = 50
  }

  memory {
    dedicated = 8192
    floating  = 8192
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = 1024
    iothread     = true
  }

  cdrom {
    interface = "ide2"
    file_id   = local.iso_ubuntu
  }

  network_device {
    bridge      = "vmbr0"
    model       = "virtio"
    mac_address = nonsensitive(local.site.hosts.ragnarok.mac)
    firewall    = true
  }

  operating_system {
    type = "l26"
  }

  startup {
    order    = 2
    up_delay = 15
  }

  lifecycle {
    prevent_destroy = true
    # The provider reads the CD-ROM back only from the interface already in state
    # (default ide3), so after an import the ide2 ISO never appears in state and the
    # block would plan an update forever. Remove this when the ISO is detached (Task 6b).
    ignore_changes = [cdrom]
  }
}
