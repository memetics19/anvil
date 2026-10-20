variable "node_name" {
  description = "Proxmox node name."
  type        = string
  default     = "pve"
}

variable "site_json" {
  description = "The site dict (IPs, MACs, VMIDs) as JSON; scripts/env.sh builds TF_VAR_site_json from the Keychain. Structure: site/site.example.yml."
  type        = string
  sensitive   = true
}
