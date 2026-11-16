terraform {
  required_version = ">= 1.10"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # The root module pins the exact version (terraform/versions.tf).
      version = ">= 0.117.0"
    }
  }
}
