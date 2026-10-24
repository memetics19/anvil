# The three VMs that existed before this repo, adopted with import blocks (imports.tf).
# Adopted to mirror `qm config`, then right-sized (Task 6b: CPU, memory, guest agent,
# discard, ISO detached, start on boot).
# VMIDs and MACs are site values (var.site_json); sizes are literals. They are not
# secrets, only kept out of the repo, so they are unwrapped with nonsensitive(): marked
# sensitive, every adopted VM would plan a sensitivity-only in-place update.

resource "proxmox_virtual_environment_vm" "frigate" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.frigate.vmid)
  name          = "frigate"
  on_boot       = true
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change; restarts are
  # done by hand, one VM at a time.
  reboot_after_update = false
  boot_order          = ["scsi0", "ide2", "net0"]

  # qemu-guest-agent runs in the guest (ansible role guest_base, make vms). The IPs are
  # site values, so the provider never waits on the agent to report them.
  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    sockets = 1
    cores   = 2
    type    = "host"
  }

  # floating = dedicated keeps the balloon device without ballooning, as on ragnarok.
  memory {
    dedicated = 6144
    floating  = 6144
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = nonsensitive(try(local.site.hosts.frigate.disk_gb, 500))
    iothread     = true
    discard      = "on"
  }

  # The install ISO is detached; the empty drive stays so the boot order is unchanged.
  cdrom {
    interface = "ide2"
    file_id   = "none"
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
  }
}

resource "proxmox_virtual_environment_vm" "netbird" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.netbird.vmid)
  name          = "netbird"
  on_boot       = true
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change; restarts are
  # done by hand, one VM at a time.
  reboot_after_update = false
  boot_order          = ["scsi0", "ide2", "net0"]

  # qemu-guest-agent runs in the guest (ansible role guest_base, make vms). The IPs are
  # site values, so the provider never waits on the agent to report them.
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

  # 3 GB: the cloud routing peer, Redis, ntfy, Pulse and the self-hosted NetBird server
  # with its routing peer (Task 13c).
  memory {
    dedicated = 3072
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = nonsensitive(try(local.site.hosts.netbird.disk_gb, 42))
    iothread     = true
    discard      = "on"
  }

  # The install ISO is detached; the empty drive stays so the boot order is unchanged.
  cdrom {
    interface = "ide2"
    file_id   = "none"
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
  }
}

# ragnarok's disk holds the media library: the only data that must survive.
resource "proxmox_virtual_environment_vm" "ragnarok" {
  node_name     = var.node_name
  vm_id         = nonsensitive(local.site.hosts.ragnarok.vmid)
  name          = "ragnarok"
  on_boot       = true
  scsi_hardware = "virtio-scsi-single"
  # Never let the provider reboot or power off a VM to apply a change; restarts are
  # done by hand, one VM at a time.
  reboot_after_update = false
  boot_order          = ["scsi0", "ide2", "net0"]

  # qemu-guest-agent runs in the guest (ansible role guest_base, make vms). The IPs are
  # site values, so the provider never waits on the agent to report them.
  agent {
    enabled = true
    wait_for_ip {
      disabled = true
    }
  }

  cpu {
    sockets = 1
    cores   = 2
    type    = "host"
    units   = 100
  }

  memory {
    dedicated = 8192
    floating  = 8192
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi0"
    size         = nonsensitive(try(local.site.hosts.ragnarok.disk_gb, 1024))
    iothread     = true
    discard      = "on"
  }

  # The install ISO is detached; the empty drive stays so the boot order is unchanged.
  cdrom {
    interface = "ide2"
    file_id   = "none"
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
  }
}
