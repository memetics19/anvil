#!/usr/bin/env bash
# Timed rollback for /etc/netplan (adapted from pve_network's net-rollback.sh).
# Usage: netplan-rollback.sh <backup-dir> (--target HOST | --force) [--wait SECONDS] [--netplan-dir PATH]
# Sleeps, pings the target, and if it is unreachable (or with --force) replaces the netplan
# files with the backup's and runs `netplan apply`.
set -u

backup=""
wait_s=0
target=""
force=0
dir=/etc/netplan

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_s=${2:?--wait needs a value}; shift 2 ;;
    --target) target=${2:?--target needs a value}; shift 2 ;;
    --netplan-dir) dir=${2:?--netplan-dir needs a value}; shift 2 ;;
    --force) force=1; shift ;;
    -*) echo "netplan-rollback: unknown option $1" >&2; exit 2 ;;
    *) backup=$1; shift ;;
  esac
done

[ -n "$backup" ] && { [ -n "$target" ] || [ "$force" = 1 ]; } || {
  echo "usage: netplan-rollback.sh <backup-dir> (--target HOST | --force) [--wait SECONDS] [--netplan-dir PATH]" >&2; exit 2; }
shopt -s nullglob
saved=("$backup"/*.yaml "$backup"/*.yml)
[ ${#saved[@]} -gt 0 ] || { echo "netplan-rollback: no netplan files in $backup" >&2; exit 1; }
[ -d "$dir" ] || { echo "netplan-rollback: $dir is not a directory" >&2; exit 1; }

sleep "$wait_s"

if [ "$force" != 1 ] && ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
  echo "netplan-rollback: $target reachable, keeping current configuration"
  exit 0
fi

echo "netplan-rollback: restoring $backup"
current=("${dir:?}"/*.yaml "${dir:?}"/*.yml)
[ ${#current[@]} -eq 0 ] || rm -f -- "${current[@]}"
cp -- "${saved[@]}" "${dir:?}"/ || { echo "netplan-rollback: restore failed" >&2; exit 1; }
chmod 0600 "${dir:?}"/*.yaml "${dir:?}"/*.yml 2>/dev/null
netplan apply
