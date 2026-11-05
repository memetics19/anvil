# The Wazuh VM: the security monitor (role wazuh_server) on the second Proxmox node
# (site.hosts.wazuh.node). Created only when site.hosts.wazuh exists.
#
# One NIC on the lab network: every agent reports to it there, and the gateway proxies the
# dashboard. Its disk holds the alert history (indexer data): replaceable, but losing it loses
# the past, so cores, memory and disk are sized for a year of a small lab.

locals {
  wazuh      = try(local.site.hosts.wazuh, null)
  wazuh_node = try(local.site.hosts.wazuh.node, var.node_name)
}

module "wazuh" {
  source = "./modules/ubuntu_vm"
  count  = local.wazuh == null ? 0 : 1

  name      = "wazuh"
  node      = local.wazuh_node
  vm_id     = nonsensitive(local.wazuh.vmid)
  cores     = nonsensitive(try(local.wazuh.cores, 4))
  memory_mb = nonsensitive(try(local.wazuh.memory_mb, 8192))
  datastore = nonsensitive(try(local.wazuh.datastore, "vmdata"))
  disk_gb   = nonsensitive(try(local.wazuh.disk_gb, 80))
  image_id  = proxmox_virtual_environment_download_file.noble_cloudimg[local.wazuh_node].id

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.wazuh.mac), address = "${local.wazuh.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}

moved {
  from = proxmox_virtual_environment_vm.wazuh[0]
  to   = module.wazuh[0].proxmox_virtual_environment_vm.this
}
