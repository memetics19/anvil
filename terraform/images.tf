# The Ubuntu 24.04 cloud image new VMs are made from, pinned to one release and checksum. One
# copy per Proxmox node that runs such a VM: a cloud image in a node's local store (its import
# store, enabled by the pve_host role, tag storage) can only be imported on that node.
#
# Bumping the image: changing the URL or checksum makes the provider replace the download,
# which plan-guard rejects. Do not edit it in place. Add a second pinned image (new name, new
# file_name) for new VMs. Existing VMs never re-import: each ignores disk[0].import_from.

locals {
  # The VMs made from the image that may run on another node (site.hosts.<name>.node). The
  # others (vault, apps, vaultwarden) run on var.node_name.
  image_vms = ["identity", "wazuh", "monitoring"]
  # Node names are not secret (every plan shows them as node_name), but the site dict is
  # sensitive as a whole, so the set is marked plain for for_each.
  image_nodes = nonsensitive(toset(concat([var.node_name], [
    for h in local.image_vms : try(local.site.hosts[h].node, var.node_name)
    if try(local.site.hosts[h], null) != null
  ])))
}

resource "proxmox_virtual_environment_download_file" "noble_cloudimg" {
  for_each            = local.image_nodes
  node_name           = each.key
  datastore_id        = "local"
  content_type        = "import"
  file_name           = "ubuntu-24.04-server-cloudimg-amd64-20261017.qcow2"
  url                 = "https://cloud-images.ubuntu.com/releases/noble/release-20261017/ubuntu-24.04-server-cloudimg-amd64.img"
  checksum            = "04e8f2461a16a44e78a370284471f29616cdd9baf1893df25807b71f985b6c94"
  checksum_algorithm  = "sha256"
  overwrite           = false
  overwrite_unmanaged = false
}

# Each VM used to have its own download. The five on the second node all managed the same file,
# so destroying any one of them would have deleted the image the others came from. The main
# node's and one second-node copy move here. The other four are only forgotten: the file stays.
moved {
  from = proxmox_virtual_environment_download_file.noble_cloudimg
  to   = proxmox_virtual_environment_download_file.noble_cloudimg["pve"]
}

moved {
  from = proxmox_virtual_environment_download_file.noble_cloudimg_identity[0]
  to   = proxmox_virtual_environment_download_file.noble_cloudimg["pve2"]
}

removed {
  from = proxmox_virtual_environment_download_file.noble_cloudimg_llm
  lifecycle {
    destroy = false
  }
}

removed {
  from = proxmox_virtual_environment_download_file.noble_cloudimg_canary
  lifecycle {
    destroy = false
  }
}

removed {
  from = proxmox_virtual_environment_download_file.noble_cloudimg_wazuh
  lifecycle {
    destroy = false
  }
}

removed {
  from = proxmox_virtual_environment_download_file.noble_cloudimg_monitoring
  lifecycle {
    destroy = false
  }
}
