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

module "identity" {
  source = "./modules/ubuntu_vm"
  count  = local.identity == null ? 0 : 1

  name          = "identity"
  node          = local.identity_node
  vm_id         = nonsensitive(local.identity.vmid)
  cores         = nonsensitive(try(local.identity.cores, 2))
  cpu_type      = "host"
  memory_mb     = nonsensitive(try(local.identity.memory_mb, 3072))
  datastore     = nonsensitive(try(local.identity.datastore, "vmdata"))
  disk_gb       = nonsensitive(try(local.identity.disk_gb, 32))
  image_id      = proxmox_virtual_environment_download_file.noble_cloudimg[local.identity_node].id
  startup_order = 1

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.identity.mac), address = "${local.identity.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
    # net1: home network, no gateway.
    { mac = nonsensitive(local.identity.home_mac), address = "${local.identity.home_ip}/${local.site.pve.uplink_prefix}" },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}

moved {
  from = proxmox_virtual_environment_vm.identity[0]
  to   = module.identity[0].proxmox_virtual_environment_vm.this
}
