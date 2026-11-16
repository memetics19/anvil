# The LLM VM: a local language model (Ollama) with a chat UI (Open WebUI), on the second
# Proxmox node (site.hosts.llm.node). Created only when site.hosts.llm exists.
#
# One NIC on the lab network with the default route: the gateway proxies llm.<domain> to it,
# Pulse reaches it, and it has internet to pull the model. No home NIC (nothing on the home
# network talks to it directly). CPU inference only; these hosts have no GPU.
# Its disk is on that node's data pool (site.hosts.llm.datastore, default vmdata). It holds
# only the model cache and chat history, both replaceable.

locals {
  llm      = try(local.site.hosts.llm, null)
  llm_node = try(local.site.hosts.llm.node, var.node_name)
}

module "llm" {
  source = "./modules/ubuntu_vm"
  count  = local.llm == null ? 0 : 1

  name     = "llm"
  node     = local.llm_node
  vm_id    = nonsensitive(local.llm.vmid)
  cores    = nonsensitive(try(local.llm.cores, 4))
  cpu_type = "host"
  # The model (Hermes 3 8B, Q4, about 5 GB) plus Open WebUI and the OS. Modest on purpose.
  memory_mb = nonsensitive(try(local.llm.memory_mb, 16384))
  datastore = nonsensitive(try(local.llm.datastore, "vmdata"))
  disk_gb   = nonsensitive(try(local.llm.disk_gb, 40))
  image_id  = proxmox_virtual_environment_download_file.noble_cloudimg[local.llm_node].id

  nics = [
    # net0: lab network, default route.
    { mac = nonsensitive(local.llm.mac), address = "${local.llm.ip}/${split("/", local.site.lan_cidr)[1]}", gateway = local.site.pve.gateway_alias_ip },
  ]

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  dns_domain     = local.site.domain
  dns_servers    = local.site.guest_dns
}

moved {
  from = proxmox_virtual_environment_vm.llm[0]
  to   = module.llm[0].proxmox_virtual_environment_vm.this
}
