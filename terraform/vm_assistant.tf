# The assistant VM: the operator's assistant (Hermes, talking on WhatsApp, role hermes) and the
# watchers that send Gotify alerts (role watchers), on the second Proxmox node
# (site.hosts.assistant.node). Created only when site.hosts.assistant exists.
#
# One NIC on the lab network. Nothing listens for the internet: WhatsApp and the watchers
# only connect out. Its disk holds the assistant's memory and the watchers' state:
# replaceable, but losing it loses the WhatsApp pairing and the price history.

locals {
  assistant      = try(local.site.hosts.assistant, null)
  assistant_node = try(local.site.hosts.assistant.node, var.node_name)
}

module "assistant" {
  source = "./modules/ubuntu_vm"
  count  = local.assistant == null ? 0 : 1

  name      = "assistant"
  node      = local.assistant_node
  vm_id     = nonsensitive(local.assistant.vmid)
  cores     = nonsensitive(try(local.assistant.cores, 2))
  memory_mb = nonsensitive(try(local.assistant.memory_mb, 4096))
  datastore = nonsensitive(try(local.assistant.datastore, "vmdata"))
  disk_gb   = nonsensitive(try(local.assistant.disk_gb, 40))
  image_id  = proxmox_virtual_environment_download_file.noble_cloudimg[local.assistant_node].id

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.assistant.mac), address = "${local.assistant.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}
