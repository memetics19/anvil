# The apps VM: small always-on services shared on one VM to save memory (Pi-hole now,
# Vaultwarden later). A modules/ubuntu_vm VM: Ubuntu 24.04 cloud image imported through the
# Proxmox API, cloud-init for user, key and static addresses, guest agent installed
# afterwards by guest_base (make vms). It is never destroyed by Terraform (the module's
# prevent_destroy, and plan-guard protects its disk too).
#
# Two NICs on vmbr0, both addressed by cloud-init (ipconfig0/ipconfig1): net0 on the lab
# network with the default route via the lab gateway like every guest, net1 on the home
# network with no gateway, so home clients reach Pi-hole directly on their own subnet.
# Proxmox cloud-init takes one address per NIC, so two NICs keep the whole network
# config in cloud-init (guest_base leaves the netplan alone, as on the vault VM).
# Addresses, MACs and VMID are site values (site.hosts.apps.{ip,home_ip,mac,home_mac,vmid}).

module "apps" {
  source = "./modules/ubuntu_vm"

  name          = "apps"
  node          = var.node_name
  vm_id         = nonsensitive(local.site.hosts.apps.vmid)
  cores         = 1
  memory_mb     = 1536
  datastore     = "local-lvm"
  disk_gb       = nonsensitive(try(local.site.hosts.apps.disk_gb, 16))
  image_id      = proxmox_virtual_environment_download_file.noble_cloudimg[var.node_name].id
  startup_order = 1

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.site.hosts.apps.mac), address = "${local.site.hosts.apps.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
    # net1: home network, no gateway.
    { mac = nonsensitive(local.site.hosts.apps.home_mac), address = "${local.site.hosts.apps.home_ip}/${local.site.pve.uplink_prefix}" },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}

moved {
  from = proxmox_virtual_environment_vm.apps
  to   = module.apps.proxmox_virtual_environment_vm.this
}
