# VMs retired on purpose: Terraform forgets them and destroys nothing. Each was deleted in
# Proxmox first (modules/ubuntu_vm says how to retire a VM). Kept until no state names them.

# The local language model (Ollama + Open WebUI) and the tripwire (OpenCanary), both on the
# second node, retired 2026-11-06.
removed {
  from = proxmox_virtual_environment_vm.llm
  lifecycle {
    destroy = false
  }
}

removed {
  from = proxmox_virtual_environment_vm.canary
  lifecycle {
    destroy = false
  }
}
