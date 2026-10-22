#!/usr/bin/env bash
# Timed rollback for the segments firewall (role pve_segments), like net-rollback.sh: sleeps,
# pings the target, and if it is unreachable puts the previous table back from the backup (an
# `nft list table` dump), or removes the table when the backup is empty (there was none).
# With --file SAVED --to PATH it also puts the ruleset file back (SAVED empty: removes PATH),
# so the next run sees the difference and applies again.
# Usage: segments-fw-rollback.sh <backup-file> --target HOST [--wait SECONDS] [--table NAME]
#        [--file SAVED --to PATH]
set -u

backup=""
wait_s=0
target=""
table=segments
saved=""
dest=""
NFT=${NFT:-nft}

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_s=${2:?--wait needs a value}; shift 2 ;;
    --target) target=${2:?--target needs a value}; shift 2 ;;
    --table) table=${2:?--table needs a value}; shift 2 ;;
    --file) saved=${2:?--file needs a value}; shift 2 ;;
    --to) dest=${2:?--to needs a value}; shift 2 ;;
    -*) echo "segments-fw-rollback: unknown option $1" >&2; exit 2 ;;
    *) backup=$1; shift ;;
  esac
done

[ -n "$backup" ] && [ -n "$target" ] || { echo "usage: segments-fw-rollback.sh <backup-file> --target HOST [--wait SECONDS] [--table NAME] [--file SAVED --to PATH]" >&2; exit 2; }
[[ $table =~ ^[a-z][a-z0-9_]*$ ]] || { echo "segments-fw-rollback: bad table name" >&2; exit 2; }
[ -f "$backup" ] || { echo "segments-fw-rollback: backup $backup not found" >&2; exit 1; }

sleep "$wait_s"

if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
  echo "segments-fw-rollback: $target reachable, keeping the current table"
  exit 0
fi

echo "segments-fw-rollback: $target unreachable, restoring the previous table"
{ printf 'table inet %s\ndelete table inet %s\n' "$table" "$table"; cat "$backup"; } | "$NFT" -f - || exit 1
if [ -n "$saved" ] && [ -n "$dest" ]; then
  if [ -s "$saved" ]; then cp "$saved" "$dest"; else rm -f "$dest"; fi
fi
