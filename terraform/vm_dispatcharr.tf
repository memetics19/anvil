# The Dispatcharr VM: IPTV playlists, guides and a stream proxy (role dispatcharr) on the
# second Proxmox node (site.hosts.dispatcharr.node). Created only when site.hosts.dispatcharr
# exists.
#
# One NIC on the lab network: the gateway proxies it to players. Its disk holds the
# database, logos and any recordings: replaceable, but losing it loses the channel setup.

locals {
  dispatcharr      = try(local.site.hosts.dispatcharr, null)
  dispatcharr_node = try(local.site.hosts.dispatcharr.node, var.node_name)
}

module "dispatcharr" {
  source = "./modules/ubuntu_vm"
  count  = local.dispatcharr == null ? 0 : 1

  name      = "dispatcharr"
  node      = local.dispatcharr_node
  vm_id     = nonsensitive(local.dispatcharr.vmid)
  cores     = nonsensitive(try(local.dispatcharr.cores, 2))
  memory_mb = nonsensitive(try(local.dispatcharr.memory_mb, 3072))
  datastore = nonsensitive(try(local.dispatcharr.datastore, "vmdata"))
  disk_gb   = nonsensitive(try(local.dispatcharr.disk_gb, 40))
  image_id  = proxmox_virtual_environment_download_file.noble_cloudimg[local.dispatcharr_node].id

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.dispatcharr.mac), address = "${local.dispatcharr.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}
