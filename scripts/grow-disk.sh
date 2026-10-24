#!/usr/bin/env bash
# grow-disk.sh: make a VM's disk bigger while it runs, as code (anvil increase-disk).
#   1. The current size from Proxmox, the new one: current + ADD GB.
#   2. A Terraform plan with the new size (site.hosts.<vm>.disk_gb, set in this process
#      only). It must pass scripts/plan-guard.sh, and change nothing but that disk's size.
#   3. Without --check: the new size into the site dict in Vault, then that saved plan is
#      applied. Proxmox grows the disk of the running VM (the provider never reboots it:
#      reboot_after_update is false). Then the role grow_disk grows the partition and the
#      filesystem at the end of the disk, mounted. Nothing stops.
# A disk can only grow: the plan guard refuses anything smaller.
# Usage: scripts/grow-disk.sh [--check] <vm> <add-gb> [<mount>]
#   <mount>: for an LVM disk with several logical volumes, the one to grow (frigate: /home).
set -euo pipefail
cd "$(dirname "$0")/.."

log() { echo "grow-disk: $*"; }
die() { echo "grow-disk: $*" >&2; exit 1; }

check=false
[ "${1:-}" = --check ] && { check=true; shift; }
vm=${1:-}
add=${2:-}
mount=${3:-}
[ -n "$vm" ] && [ -n "$add" ] || die "usage: scripts/grow-disk.sh [--check] <vm> <add-gb> [<mount>]"
[[ $add =~ ^[1-9][0-9]*$ ]] || die "the size to add is whole GB, for example 600 (got '$add')"
[[ $vm =~ ^[a-z][a-z0-9_-]*$ ]] || die "not a VM name: $vm"
[ -z "$mount" ] || [[ $mount =~ ^/[A-Za-z0-9/._-]*$ ]] || die "not a mount point: $mount"

# shellcheck source=/dev/null  # env.sh ends in a top-level return
source scripts/env.sh >/dev/null
site=${TF_VAR_site_json:-}
[ -n "$site" ] || die "no site dict: scripts/env.sh could not load it"
grep -qs "resource \"proxmox_virtual_environment_vm\" \"$vm\"" terraform/*.tf ||
  die "$vm is not a VM Terraform manages. These are: $(sed -n 's/^resource "proxmox_virtual_environment_vm" "\([a-z0-9_-]*\)".*/\1/p' terraform/*.tf | sort | tr '\n' ' ')"
vmid=$(jq -r --arg v "$vm" '.hosts[$v].vmid // empty' <<<"$site")
[ -n "$vmid" ] || die "site.hosts.$vm has no vmid"

# The size Proxmox has now, in GB (scsi0, for example size=1T or size=500G).
conf=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "root@$PVE_IP" "qm config $vmid") ||
  die "cannot reach the Proxmox host over SSH. Away from home on the VPN, a lab address alias left on the Wi-Fi hides the VPN's route (docs/cli.md, No route to host on macOS)"
raw=$(awk -F'size=' '/^scsi0:/ { split($2, a, ","); print a[1] }' <<<"$conf")
case $raw in
  *T) cur=$(( ${raw%T} * 1024 )) ;;
  *G) cur=${raw%G} ;;
  *) die "cannot read the size of $vm's disk scsi0 from Proxmox (got '$raw')" ;;
esac
[[ $cur =~ ^[0-9]+$ ]] || die "$vm's disk is not a whole number of GB ($raw)"
set_size=$(jq -r --arg v "$vm" '.hosts[$v].disk_gb // empty' <<<"$site")
[ -z "$set_size" ] || [ "$set_size" = "$cur" ] ||
  die "site.hosts.$vm.disk_gb is $set_size but the disk is $cur GB: run make tf-plan and look first"
new=$((cur + add))
log "$vm: $cur GB -> $new GB"

# --- the plan --------------------------------------------------------------------------------
if [ ! -f terraform/.terraform/terraform.tfstate ]; then
  terraform -chdir=terraform init -input=false -backend-config="endpoints={s3=\"http://${PVE_IP}:7480\"}" >/dev/null
fi
umask 077
plan=terraform/homelab.tfplan
trap 'rm -f "$plan"' EXIT
TF_VAR_site_json=$(jq -c --arg v "$vm" --argjson n "$new" '.hosts[$v].disk_gb = $n' <<<"$site") \
  terraform -chdir=terraform plan -input=false -out=homelab.tfplan >/dev/null
json=$(terraform -chdir=terraform show -json homelab.tfplan)
scripts/plan-guard.sh <(printf '%s' "$json")

# The only change: this VM, updated, with only scsi0's size different (cur -> new).
want="proxmox_virtual_environment_vm.$vm"
changes=$(jq -r '[.resource_changes // [] | .[] | select(.change.actions != ["no-op"]) | .address] | join(" ")' <<<"$json")
[ "$changes" = "$want" ] || die "the plan changes more than $vm's disk: ${changes:-nothing}. Run make tf-plan and look first"
jq -e --arg a "$want" --argjson c "$cur" --argjson n "$new" '
  .resource_changes[] | select(.address == $a) | .change
  | .actions == ["update"]
    and ([.before.disk[] | select(.interface == "scsi0") | .size] == [$c])
    and ([.after.disk[] | select(.interface == "scsi0") | .size] == [$n])
    and ((.before | del(.disk[].size)) == (.after | del(.disk[].size)))' <<<"$json" >/dev/null ||
  die "the plan for $vm changes something besides scsi0's size $cur -> $new. Run make tf-plan and look first"
log "plan: only $vm's disk grows, $cur GB -> $new GB"

if $check; then
  make -s vm HOST="$vm" ARGS="--check --tags grow_disk${mount:+ -e grow_disk_mount=$mount}"
  log "check only: nothing changed"
  exit 0
fi

# --- the change ------------------------------------------------------------------------------
# The new size goes into the site dict first, so the next plan agrees with the disk. -cas
# refuses to overwrite a change made since it was read.
ver=$(vault kv metadata get -format=json -mount=kv homelab/site | jq -r '.data.current_version')
vault kv get -format=json -mount=kv homelab/site |
  jq -c --arg v "$vm" --argjson n "$new" '{site: (.data.data.site | .hosts[$v].disk_gb = $n)}' |
  vault kv put -cas="$ver" -mount=kv homelab/site - >/dev/null
log "site.hosts.$vm.disk_gb = $new in Vault"

terraform -chdir=terraform apply -input=false homelab.tfplan
log "Proxmox: $vm's disk is $new GB"

make -s vm HOST="$vm" ARGS="--tags grow_disk${mount:+ -e grow_disk_mount=$mount}"
log "done: $vm has $add GB more, nothing was stopped"
