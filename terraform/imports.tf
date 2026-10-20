# Adopt resources that existed before this repo. Import blocks are idempotent: once a
# resource is in state they are no-ops, so they stay as documentation of the adoption.

import {
  to = proxmox_virtual_environment_vm.frigate
  id = "${var.node_name}/${local.site.hosts.frigate.vmid}"
}

import {
  to = proxmox_virtual_environment_vm.netbird
  id = "${var.node_name}/${local.site.hosts.netbird.vmid}"
}

import {
  to = proxmox_virtual_environment_vm.ragnarok
  id = "${var.node_name}/${local.site.hosts.ragnarok.vmid}"
}

import {
  to = proxmox_sdn_zone_vlan.vlanzone
  id = "vlanzone"
}

import {
  to = proxmox_sdn_vnet.servers
  id = "servers"
}

import {
  to = proxmox_sdn_vnet.cameras
  id = "cameras"
}

import {
  to = proxmox_sdn_vnet.personal
  id = "personal"
}

# Proxmox names a subnet <zone>-<address>-<prefix>.
import {
  for_each = local.sdn_subnets
  to       = proxmox_sdn_subnet.this[each.key]
  id       = "${each.key}/vlanzone-${replace(each.value.cidr, "/", "-")}"
}
