variable "name" {
  description = "The VM's name in Proxmox and its hostname."
  type        = string
}

variable "node" {
  description = "The Proxmox node it runs on."
  type        = string
}

variable "vm_id" {
  description = "The Proxmox VMID."
  type        = number
}

variable "cores" {
  description = "vCPUs, on one socket."
  type        = number
}

variable "cpu_type" {
  description = "QEMU CPU type. x86-64-v2-AES can live-migrate between the nodes. host is faster but pins the VM to its node's CPU."
  type        = string
  default     = "x86-64-v2-AES"
}

variable "memory_mb" {
  description = "Memory in MB, all of it dedicated (no ballooning below it)."
  type        = number
}

variable "datastore" {
  description = "Where the disk and the cloud-init drive live."
  type        = string
}

variable "disk_gb" {
  description = "Size of the system disk."
  type        = number
}

variable "image_id" {
  description = "The cloud image the disk is imported from (proxmox_virtual_environment_download_file id, on the same node). Only read when the disk is created."
  type        = string
}

variable "nics" {
  description = "The NICs, all on vmbr0, in order (net0, net1). address is ip/prefix for cloud-init. Only net0 gets a gateway (the default route)."
  type = list(object({
    mac     = string
    address = string
    gateway = optional(string)
  }))

  validation {
    condition     = length(var.nics) >= 1
    error_message = "A VM needs at least one NIC."
  }
}

variable "ssh_public_key" {
  description = "The operator's public key, for the ubuntu user."
  type        = string
}

variable "dns_domain" {
  description = "The search domain cloud-init writes."
  type        = string
}

variable "dns_servers" {
  description = "The resolvers cloud-init writes."
  type        = list(string)
}

variable "startup_order" {
  description = "Proxmox boot order: lower boots first."
  type        = number
  default     = 2
}
