#!/usr/bin/env bash
# Timed rollback for /etc/network/interfaces.
# Usage: net-rollback.sh <backup-file> [--wait SECONDS] [--target HOST] [--interfaces-file PATH]
# Sleeps, pings the target, and if it is unreachable restores the backup and runs `ifreload -a`.
set -u

backup=""
wait_s=0
target=""
iface_file=/etc/network/interfaces

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_s=${2:?--wait needs a value}; shift 2 ;;
    --target) target=${2:?--target needs a value}; shift 2 ;;
    --interfaces-file) iface_file=${2:?--interfaces-file needs a value}; shift 2 ;;
    -*) echo "net-rollback: unknown option $1" >&2; exit 2 ;;
    *) backup=$1; shift ;;
  esac
done

[ -n "$backup" ] && [ -n "$target" ] || { echo "usage: net-rollback.sh <backup-file> --target HOST [--wait SECONDS] [--interfaces-file PATH]" >&2; exit 2; }
[ -f "$backup" ] || { echo "net-rollback: backup $backup not found" >&2; exit 1; }

sleep "$wait_s"

if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
  echo "net-rollback: $target reachable, keeping current configuration"
  exit 0
fi

echo "net-rollback: $target unreachable, restoring $backup"
cp "$backup" "$iface_file" || { echo "net-rollback: restore failed" >&2; exit 1; }
chmod 0644 "$iface_file"
ifreload -a
