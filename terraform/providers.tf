# Endpoint, API token and TLS mode come from the environment
# (PROXMOX_VE_ENDPOINT, PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE) set by scripts/env.sh.
provider "proxmox" {}
