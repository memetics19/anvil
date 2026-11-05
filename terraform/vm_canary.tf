# The canary VM: a tripwire (OpenCanary, role canary) on the second Proxmox node
# (site.hosts.canary.node). Created only when site.hosts.canary exists.
#
# Nothing legitimate ever talks to it, so any connection, login attempt or port scan is an
# alarm. One NIC on the lab network, where an intruder would look. Small, and it holds nothing,
# so it can be rebuilt any time (modules/ubuntu_vm says how to retire a VM).

locals {
  canary      = try(local.site.hosts.canary, null)
  canary_node = try(local.site.hosts.canary.node, var.node_name)
}

module "canary" {
  source = "./modules/ubuntu_vm"
  count  = local.canary == null ? 0 : 1

  name      = "canary"
  node      = local.canary_node
  vm_id     = nonsensitive(local.canary.vmid)
  cores     = 1
  memory_mb = nonsensitive(try(local.canary.memory_mb, 1024))
  datastore = nonsensitive(try(local.canary.datastore, "vmdata"))
  disk_gb   = nonsensitive(try(local.canary.disk_gb, 12))
  image_id  = proxmox_virtual_environment_download_file.noble_cloudimg[local.canary_node].id

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.canary.mac), address = "${local.canary.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}

moved {
  from = proxmox_virtual_environment_vm.canary[0]
  to   = module.canary[0].proxmox_virtual_environment_vm.this
}
