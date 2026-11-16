# The monitoring VM: metrics, dashboards and alerts (role monitoring, docs/monitoring.md) on
# the second Proxmox node (site.hosts.monitoring.node). Created only when
# site.hosts.monitoring exists.
#
# One NIC on the lab network: it scrapes every host there, and the gateway proxies Grafana.
# Its disk holds 90 days of metrics: replaceable, but losing it loses the history.

locals {
  monitoring      = try(local.site.hosts.monitoring, null)
  monitoring_node = try(local.site.hosts.monitoring.node, var.node_name)
}

module "monitoring" {
  source = "./modules/ubuntu_vm"
  count  = local.monitoring == null ? 0 : 1

  name      = "monitoring"
  node      = local.monitoring_node
  vm_id     = nonsensitive(local.monitoring.vmid)
  cores     = nonsensitive(try(local.monitoring.cores, 2))
  memory_mb = nonsensitive(try(local.monitoring.memory_mb, 4096))
  datastore = nonsensitive(try(local.monitoring.datastore, "vmdata"))
  disk_gb   = nonsensitive(try(local.monitoring.disk_gb, 60))
  image_id  = proxmox_virtual_environment_download_file.noble_cloudimg[local.monitoring_node].id

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.monitoring.mac), address = "${local.monitoring.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}

moved {
  from = proxmox_virtual_environment_vm.monitoring[0]
  to   = module.monitoring[0].proxmox_virtual_environment_vm.this
}
