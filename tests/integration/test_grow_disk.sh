#!/usr/bin/env bash
# SC2024: the output files are the test user's own, written without sudo on purpose.
# SC2015: ok never fails, so A && ok || bad_ is a plain if-else. SC2329: cleanup runs on EXIT.
# shellcheck disable=SC2024,SC2015,SC2329
# grow-disk (role grow_disk) on real block devices: loop devices with GPT partitions,
# ext4 and LVM, mounted while they grow. Needs Linux, root (sudo), sgdisk, growpart and
# the LVM tools; elsewhere it is skipped. CI runs it on Ubuntu.
#  - ragnarok's layout: the last partition (ext4, mounted) grows to the end, its data stays;
#  - cloud-image numbering: the partition that ends last grows, not the highest number;
#  - LVM with one volume, and with two (the mount point picks which one grows);
#  - a second run changes nothing; --check changes nothing.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
script=$PWD/ansible/roles/grow_disk/files/grow-disk.sh

# skip <why>: fine on a laptop, a failure in CI, where the test must really run.
skip() { if [ -n "${CI:-}" ]; then echo "FAIL: cannot run in CI: $1"; exit 1; fi; echo "SKIP: $1"; exit 0; }
if [ "$(uname)" != Linux ] || ! sudo -n true 2>/dev/null; then skip "needs Linux and passwordless sudo"; fi
for t in sgdisk growpart pvcreate mkfs.ext4 losetup partprobe; do
  command -v "$t" >/dev/null || skip "$t missing"
done

tmp=$(mktemp -d)
loops=() mounts=() vgs=()
cleanup() {
  for m in "${mounts[@]}"; do sudo umount "$m" 2>/dev/null; done
  for v in "${vgs[@]}"; do sudo vgchange -an "$v" >/dev/null 2>&1; done
  for l in "${loops[@]}"; do sudo losetup -d "$l" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
size_of() { sudo blockdev --getsize64 "$1"; }
fs_size() { df -B1 --output=size "$1" | tail -n 1 | tr -d ' '; }

# disk <name> <MiB>: a sparse file on a loop device with partition scanning
disk() {
  truncate -s "$2M" "$tmp/$1.img"
  local l
  l=$(sudo losetup -fP --show "$tmp/$1.img")
  loops+=("$l")
  echo "$l"
}
# enlarge <name> <loop> <MiB>: what the hypervisor does, the disk only
enlarge() { truncate -s "$3M" "$tmp/$1.img"; sudo losetup -c "$2"; }
mnt() { mkdir -p "$tmp/m/$1"; sudo mount "$2" "$tmp/m/$1"; mounts+=("$tmp/m/$1"); echo "$tmp/m/$1"; }

# 1. ragnarok's layout: boot, root, then the data partition last
d=$(disk plain 96)
sudo sgdisk -n1:0:+8M -n2:0:+16M -n3:0:0 "$d" >/dev/null && sudo partprobe "$d"
sudo mkfs.ext4 -q "${d}p3"
m=$(mnt plain "${d}p3")
echo "the library" | sudo tee "$m/movie.mkv" >/dev/null
before=$(fs_size "$m")
enlarge plain "$d" 192
if sudo "$script" "$d" >"$tmp/out" 2>&1; then ok "grows the last partition"; else bad_ "grows the last partition"; cat "$tmp/out"; fi
after=$(fs_size "$m")
[ "$after" -gt $((before + 80 * 1024 * 1024)) ] && ok "the filesystem got the new space while mounted" || bad_ "filesystem $before -> $after"
[ "$(cat "$m/movie.mkv")" = "the library" ] && ok "the data is unchanged" || bad_ "data"
findmnt "$m" >/dev/null && ok "still mounted" || bad_ "unmounted"
p2=$(size_of "${d}p2")
[ "$p2" -eq $((16 * 1024 * 1024)) ] && ok "the partition before it is untouched" || bad_ "p2 is $p2"
if sudo "$script" "$d" >"$tmp/out" 2>&1 && grep -q "already reaches the end" "$tmp/out" && [ "$(fs_size "$m")" = "$after" ]; then
  ok "a second run changes nothing"; else bad_ "second run"; cat "$tmp/out"; fi
enlarge plain "$d" 256
if sudo "$script" --check "$d" >"$tmp/out" 2>&1 && grep -q "would run: growpart" "$tmp/out" && [ "$(fs_size "$m")" = "$after" ]; then
  ok "--check reports and changes nothing"; else bad_ "--check"; cat "$tmp/out"; fi

# 2. cloud-image numbering: partition 1 is the one at the end of the disk
d=$(disk cloud 64)
sudo sgdisk -n2:0:+8M -n1:0:0 "$d" >/dev/null && sudo partprobe "$d"
sudo mkfs.ext4 -q "${d}p1"
m=$(mnt cloud "${d}p1")
before=$(fs_size "$m")
enlarge cloud "$d" 128
if sudo "$script" "$d" >"$tmp/out" 2>&1 && grep -q "last partition is ${d}p1" "$tmp/out" && [ "$(fs_size "$m")" -gt "$before" ]; then
  ok "the partition that ends last grows, whatever its number"; else bad_ "cloud layout"; cat "$tmp/out"; fi

# 3. LVM, one logical volume
d=$(disk lvm1 64)
sudo sgdisk -n1:0:+8M -n2:0:0 "$d" >/dev/null && sudo partprobe "$d"
vg=gdtest1$$; vgs+=("$vg")
sudo pvcreate -q "${d}p2" && sudo vgcreate -q "$vg" "${d}p2" && sudo lvcreate -q -l 100%FREE -n data "$vg" -y >/dev/null
sudo mkfs.ext4 -q "/dev/$vg/data"
m=$(mnt lvm1 "/dev/$vg/data")
before=$(fs_size "$m")
enlarge lvm1 "$d" 128
if sudo "$script" "$d" >"$tmp/out" 2>&1 && [ "$(fs_size "$m")" -gt $((before + 40 * 1024 * 1024)) ]; then
  ok "LVM: the PV and the only volume grow, with its filesystem"; else bad_ "LVM one volume"; cat "$tmp/out"; fi

# 4. LVM, two logical volumes: refused without a mount point, the named one grows
d=$(disk lvm2 96)
sudo sgdisk -n1:0:+8M -n2:0:0 "$d" >/dev/null && sudo partprobe "$d"
vg=gdtest2$$; vgs+=("$vg")
sudo pvcreate -q "${d}p2" && sudo vgcreate -q "$vg" "${d}p2"
sudo lvcreate -q -L 32M -n root "$vg" -y >/dev/null && sudo lvcreate -q -l 100%FREE -n home "$vg" -y >/dev/null
sudo mkfs.ext4 -q "/dev/$vg/root"; sudo mkfs.ext4 -q "/dev/$vg/home"
mr=$(mnt lvm2root "/dev/$vg/root"); mh=$(mnt lvm2home "/dev/$vg/home")
root_before=$(fs_size "$mr"); home_before=$(fs_size "$mh")
enlarge lvm2 "$d" 160
if sudo "$script" "$d" >"$tmp/out" 2>&1; then bad_ "two volumes without a mount point is refused"; else
  grep -q "name the mount point" "$tmp/out" && ok "two volumes without a mount point is refused" || { bad_ "refusal message"; cat "$tmp/out"; }; fi
if sudo "$script" "$d" "$mh" >"$tmp/out" 2>&1 && [ "$(fs_size "$mh")" -gt "$home_before" ] && [ "$(fs_size "$mr")" = "$root_before" ]; then
  ok "the volume at the named mount point grows, the other does not"; else bad_ "LVM named mount"; cat "$tmp/out"; fi

[ "$fail" = 0 ] && echo "PASS: grow-disk" || echo "FAIL: grow-disk"
exit "$fail"
