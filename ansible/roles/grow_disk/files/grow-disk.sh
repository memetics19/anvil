#!/bin/bash
# grow-disk: after the hypervisor made a disk bigger, grow what is at its end to use the new
# space, online (nothing is unmounted or stopped):
#   - the partition that ends last on the disk, to the end of the disk (growpart);
#   - its filesystem (ext4: resize2fs, xfs: xfs_growfs);
#   - or, for an LVM physical volume, the PV and then the logical volume mounted at MOUNT
#     (with its filesystem). MOUNT may be left out when the volume group has one volume.
# Nothing is ever made smaller or created. Running it again changes nothing.
# Usage: grow-disk [--check] DISK [MOUNT]     (--check prints what it would do)
set -euo pipefail

check=false
[ "${1:-}" = --check ] && { check=true; shift; }
disk=${1:?usage: grow-disk [--check] DISK [MOUNT]}
mount=${2:-}
log() { echo "grow-disk: $*"; }
die() { echo "grow-disk: $*" >&2; exit 1; }
run() { if $check; then log "would run: $*"; else "$@"; fi; }

[ -b "$disk" ] || die "$disk is not a block device"
# Make the kernel read the disk's new size (a resized virtual disk). Read-only for data.
rescan=/sys/class/block/$(basename "$disk")/device/rescan
[ -w "$rescan" ] && echo 1 >"$rescan"

# The partition that ends last: on cloud images the numbers are not in disk order.
part=$(sfdisk -d "$disk" | awk -F'[ :=,]+' '/^\/dev\// { if ($3 + $5 > end) { end = $3 + $5; p = $1 } } END { print p }')
[ -n "$part" ] || die "$disk has no partition"
num=$(cat "/sys/class/block/$(basename "$part")/partition")
# blkid reads the signature on the device itself. lsblk would also list what is inside it
# (an LVM volume's ext4) and depends on udev having caught up.
fstype_of() { blkid -o value -s TYPE "$1" 2>/dev/null || true; }
fstype=$(fstype_of "$part")
log "$disk: the last partition is $part ($fstype)"

# growpart --dry-run: 0 when it would grow, 1 with NOCHANGE when the partition already
# reaches the end of the disk. Anything else is an error.
set +e
dry=$(growpart --dry-run "$disk" "$num" 2>&1)
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  run growpart "$disk" "$num"
  $check || partx -u "$disk" 2>/dev/null || true
elif printf '%s' "$dry" | grep -q NOCHANGE; then
  log "$part already reaches the end of $disk"
else
  die "growpart: $dry"
fi

# Grow a filesystem to fill its device: resize2fs and xfs_growfs do nothing when it
# already does, so this also finishes a run that stopped after growpart.
grow_fs() { # grow_fs <device> <fstype>
  local mnt
  case $2 in
    ext4) run resize2fs "$1" ;;
    xfs)
      mnt=$(findmnt -no TARGET --source "$1" | head -n 1)
      [ -n "$mnt" ] || die "$1 (xfs) is not mounted: xfs grows only when mounted"
      run xfs_growfs "$mnt" ;;
    *) die "$1 is $2: only ext4 and xfs are grown" ;;
  esac
}

case $fstype in
  ext4 | xfs)
    [ -z "$mount" ] || [ "$(findmnt -no SOURCE "$mount" 2>/dev/null)" = "$part" ] ||
      die "$mount is not on $part, the partition at the end of $disk"
    grow_fs "$part" "$fstype" ;;
  LVM2_member)
    run pvresize "$part"
    vg=$(pvs --noheadings -o vg_name "$part" | tr -d ' ')
    [ -n "$vg" ] || die "$part is not in a volume group"
    if [ -n "$mount" ]; then
      lv=$(findmnt -no SOURCE "$mount" 2>/dev/null) || die "$mount is not mounted"
      [ "$(lvs --noheadings -o vg_name "$lv" 2>/dev/null | tr -d ' ')" = "$vg" ] ||
        die "$mount ($lv) is not in the volume group $vg on $part"
    else
      mapfile -t lvs < <(lvs --noheadings -o lv_path "$vg" | tr -d ' ')
      [ "${#lvs[@]}" -eq 1 ] || die "$vg has ${#lvs[@]} logical volumes: name the mount point to grow"
      lv=${lvs[0]}
    fi
    free=$(vgs --noheadings -o vg_free_count "$vg" | tr -d ' ')
    if $check || [ "${free:-0}" -gt 0 ]; then
      # -r grows the filesystem with it.
      run lvextend -r -l +100%FREE "$lv"
    else
      log "$vg has no free space left: $lv is already as big as it can be"
      grow_fs "$lv" "$(fstype_of "$lv")"
    fi ;;
  *) die "$part is ${fstype:-not formatted}: only ext4, xfs and LVM are grown" ;;
esac
$check || log "done"
