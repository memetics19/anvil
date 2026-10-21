variable "node_name" {
  description = "Proxmox node name."
  type        = string
  default     = "pve"
}

variable "site_json" {
  description = "The site dict (IPs, MACs, VMIDs) as JSON; scripts/env.sh builds TF_VAR_site_json from the Keychain. Structure: site/site.example.yml."
  type        = string
  sensitive   = true

  validation {
    condition     = can(jsondecode(var.site_json).hosts)
    error_message = "site_json must be the JSON form of the site dict (see site/site.example.yml)."
  }

  # Quoted MACs survive YAML; an unquoted one made only of digits and colons is read by
  # YAML 1.1 as a base-60 number. jsonencode() tells a JSON string from a number.
  validation {
    condition = alltrue([for h in ["frigate", "netbird", "ragnarok"] : (
      can(regex("^\"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\"$", jsonencode(jsondecode(var.site_json).hosts[h].mac))) &&
      can(regex("^[0-9]+$", jsonencode(jsondecode(var.site_json).hosts[h].vmid)))
    )])
    error_message = "site.hosts.{frigate,netbird,ragnarok} need mac as a quoted string aa:bb:cc:dd:ee:ff and vmid as a number."
  }

  validation {
    condition = (
      can(regex("^[0-9.]+$", jsondecode(var.site_json).hosts.vault.ip)) &&
      can(regex("^[0-9]+$", jsonencode(jsondecode(var.site_json).hosts.vault.vmid)))
    )
    error_message = "site.hosts.vault needs ip (a.b.c.d) and vmid (a number)."
  }

  validation {
    condition = (
      can(regex("^[0-9.]+$", jsondecode(var.site_json).hosts.apps.ip)) &&
      can(regex("^[0-9.]+$", jsondecode(var.site_json).hosts.apps.home_ip)) &&
      can(regex("^[0-9]+$", jsonencode(jsondecode(var.site_json).hosts.apps.vmid))) &&
      can(regex("^[0-9]+$", jsonencode(jsondecode(var.site_json).pve.uplink_prefix))) &&
      alltrue([for k in ["mac", "home_mac"] :
      can(regex("^\"([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}\"$", jsonencode(jsondecode(var.site_json).hosts.apps[k])))])
    )
    error_message = "site.hosts.apps needs ip (lab, a.b.c.d), home_ip (home network, a.b.c.d), mac and home_mac (quoted aa:bb:cc:dd:ee:ff) and vmid (a number), and site.pve.uplink_prefix (a number)."
  }

  validation {
    condition = alltrue([for v in ["servers", "cameras", "personal"] : (
      can(cidrhost(jsondecode(var.site_json).sdn.subnets[v].cidr, 0)) &&
      can(regex("^[0-9.]+$", jsondecode(var.site_json).sdn.subnets[v].gateway))
    )])
    error_message = "site.sdn.subnets.{servers,cameras,personal} need cidr (a.b.c.d/n) and gateway (a.b.c.d); add them to the site dict (Keychain site-bootstrap or Vault)."
  }

  validation {
    condition = (
      can(cidrhost(jsondecode(var.site_json).sdn.enclave.subnet, 0)) &&
      can(regex("^[0-9.]+$", jsondecode(var.site_json).sdn.enclave.gateway))
    )
    error_message = "site.sdn.enclave needs subnet (a.b.c.d/n) and gateway (a.b.c.d): the secrets enclave's network (pve_enclave role)."
  }
}

variable "ssh_public_key_path" {
  description = "Public key installed for the ubuntu user on the cloud-init VMs (vault, apps; read at plan time, never committed)."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
