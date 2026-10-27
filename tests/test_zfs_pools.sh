#!/usr/bin/env bash
# SC2024: the output file is the test user's own, written without sudo on purpose.
# SC2015: ok never fails, so A && ok || bad_ is a plain if-else. SC2329: cleanup runs on EXIT.
# shellcheck disable=SC2015,SC2024,SC2329
# zfs-pools.py (role zfs_pools) with real ZFS on loop devices, named in a by-id directory
# of its own. Needs Linux, root (sudo), the ZFS tools and losetup; elsewhere it is skipped.
# CI runs it on Ubuntu.
#  - check mode creates nothing; a mirror and a raidz1 are created ONLINE; a second run
#    changes nothing;
#  - an existing pool declared with other disks is an error, and nothing changes;
#  - a disk in a pool is refused; a disk with an old filesystem is refused, and wiped
#    only with --wipe naming its pool;
#  - bad declarations (rpool, too few disks, a partition) stop before anything is read.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
script=$PWD/ansible/roles/zfs_pools/files/zfs-pools.py

skip() { if [ -n "${CI:-}" ]; then echo "FAIL: cannot run in CI: $1"; exit 1; fi; echo "SKIP: $1"; exit 0; }
if [ "$(uname)" != Linux ] || ! sudo -n true 2>/dev/null; then skip "needs Linux and passwordless sudo"; fi
for t in zpool losetup mkfs.ext4 wipefs; do
  command -v "$t" >/dev/null || sudo sh -c "command -v $t" >/dev/null || skip "$t missing"
done

tmp=$(mktemp -d)
ids=$tmp/by-id
mkdir -p "$ids"
loops=()
p1=anviltest$$a p2=anviltest$$b
cleanup() {
  for p in "$p1" "$p2"; do sudo zpool destroy -f "$p" 2>/dev/null; done
  for l in "${loops[@]}"; do sudo losetup -d "$l" 2>/dev/null; done
  rm -rf "$tmp"
}
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }

for i in 0 1 2 3 4 5; do
  truncate -s 256M "$tmp/d$i.img"
  l=$(sudo losetup -f --show "$tmp/d$i.img")
  loops+=("$l")
  ln -s "$l" "$ids/test-disk-$i"
done
sudo mkfs.ext4 -q "${loops[4]}"

# run <pools json> [options]: the script as root, output in $tmp/out
run() {
  local json=$1
  shift
  sudo python3 "$script" "$@" --byid-dir "$ids" "$json" >"$tmp/out" 2>&1
}
pool() { printf '{"name":"%s","layout":"%s","disks":[%s]}' "$1" "$2" "$3"; }
d() { local s="" i; for i in "$@"; do s+="${s:+,}\"test-disk-$i\""; done; printf '%s' "$s"; }
exists() { sudo zpool list -H -o name "$1" >/dev/null 2>&1; }

want="[$(pool "$p1" mirror "$(d 0 1)"),$(pool "$p2" raidz1 "$(d 2 3 5)")]"

run "$want" --check && grep -q "^would create $p1: mirror of 2 disks" "$tmp/out" && ! exists "$p1" && ! exists "$p2" &&
  ok "check mode creates nothing" || bad_ "check mode: $(cat "$tmp/out")"
grep -q "test-disk-4 .*signatures: ext4" "$tmp/out" && ok "the disk list shows an old filesystem" || bad_ "disk list: $(cat "$tmp/out")"

run "$want" && [ "$(sudo zpool list -H -o health "$p1")" = ONLINE ] && [ "$(sudo zpool list -H -o health "$p2")" = ONLINE ] &&
  ok "a mirror and a raidz1 are created ONLINE" || bad_ "create: $(cat "$tmp/out")"
sudo zpool status "$p2" | grep -q raidz1 && [ "$(sudo zfs get -H -o value compression "$p1")" = lz4 ] &&
  ok "layout raidz1, compression lz4" || bad_ "pool properties"

run "$want" && grep -q "^nothing to change" "$tmp/out" && grep -q "^ok: $p1 exists with these disks" "$tmp/out" &&
  ok "a second run changes nothing" || bad_ "second run: $(cat "$tmp/out")"

! run "[$(pool "$p1" mirror "$(d 0 4)")]" && grep -q "exists with other disks" "$tmp/out" && grep -q "^nothing changed" "$tmp/out" &&
  ok "an existing pool with other disks is an error" || bad_ "other disks: $(cat "$tmp/out")"

! run "[$(pool newpool mirror "$(d 1 4)")]" && grep -q "test-disk-1 is in pool $p1" "$tmp/out" &&
  ok "a disk in a pool is refused" || bad_ "disk in pool: $(cat "$tmp/out")"

sudo zpool destroy "$p2"
p3=anviltest$$c
want3="[$(pool "$p3" mirror "$(d 4 5)")]"
! run "$want3" && grep -q "test-disk-4 holds ext4. If nothing on it is needed: --wipe $p3" "$tmp/out" && ! exists "$p3" &&
  ok "an old filesystem is refused without --wipe" || bad_ "no wipe: $(cat "$tmp/out")"
! run "$want3" --wipe someother && grep -q "no such pool declared" "$tmp/out" &&
  ok "--wipe must name a declared pool" || bad_ "wipe other: $(cat "$tmp/out")"
p2=$p3
run "$want3" --wipe "$p3" && exists "$p3" && grep -q "^do: wipe the signatures on test-disk-4" "$tmp/out" &&
  ok "--wipe wipes that pool's disks, then creates it" || bad_ "wipe: $(cat "$tmp/out")"

for bad in "[$(pool rpool mirror "$(d 0 1)")]" "[$(pool x raidz1 "$(d 0 1)")]" '[{"name":"x","layout":"mirror","disks":["a-part1","b"]}]' \
  "[$(pool x mirror "$(d 0 1)"),$(pool y mirror "$(d 1 2)")]"; do
  ! run "$bad" && grep -q "^error:" "$tmp/out" || bad_ "accepted: $bad"
done
[ "$fail" = 0 ] && ok "bad declarations are refused"

exit $fail
