# Proxmox SDN as it exists today: VLAN zone `vlanzone` on vmbr0 with three VNets.
# Nothing uses them (their gateways were OPNsense); kept as they are.

resource "proxmox_sdn_zone_vlan" "vlanzone" {
  id     = "vlanzone"
  bridge = "vmbr0"

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_sdn_vnet" "servers" {
  id    = "servers"
  zone  = proxmox_sdn_zone_vlan.vlanzone.id
  alias = "Servers VLAN 10"
  tag   = 10

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_sdn_vnet" "cameras" {
  id    = "cameras"
  zone  = proxmox_sdn_zone_vlan.vlanzone.id
  alias = "Cameras IoT VLAN 20"
  tag   = 20

  lifecycle {
    prevent_destroy = true
  }
}

resource "proxmox_sdn_vnet" "personal" {
  id    = "personal"
  zone  = proxmox_sdn_zone_vlan.vlanzone.id
  alias = "Personal VLAN 30"
  tag   = 30

  lifecycle {
    prevent_destroy = true
  }
}

# Subnets are site values: site.sdn.subnets.<vnet> = {cidr, gateway}, required (checked
# by the site_json validation). The map's keys are vnet names, not secrets.
locals {
  sdn_subnets = nonsensitive(local.site.sdn.subnets)
  sdn_vnets = {
    servers  = proxmox_sdn_vnet.servers.id
    cameras  = proxmox_sdn_vnet.cameras.id
    personal = proxmox_sdn_vnet.personal.id
  }
}

resource "proxmox_sdn_subnet" "this" {
  for_each = local.sdn_subnets

  vnet    = local.sdn_vnets[each.key]
  cidr    = each.value.cidr
  gateway = each.value.gateway

  lifecycle {
    prevent_destroy = true
  }
}
