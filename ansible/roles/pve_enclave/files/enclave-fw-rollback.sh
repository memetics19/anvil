#!/usr/bin/env bash
# Timed rollback for the enclave firewall (role pve_enclave), like net-rollback.sh: sleeps,
# pings the target, and if it is unreachable restores the previous table `inet enclave`
# from the backup (an `nft list table` dump), or removes the table when the backup says
# there was none.
# Usage: enclave-fw-rollback.sh <backup-file> --target HOST [--wait SECONDS]
set -u

backup=""
wait_s=0
target=""
NFT=${NFT:-nft}

while [ $# -gt 0 ]; do
  case "$1" in
    --wait) wait_s=${2:?--wait needs a value}; shift 2 ;;
    --target) target=${2:?--target needs a value}; shift 2 ;;
    -*) echo "enclave-fw-rollback: unknown option $1" >&2; exit 2 ;;
    *) backup=$1; shift ;;
  esac
done

[ -n "$backup" ] && [ -n "$target" ] || { echo "usage: enclave-fw-rollback.sh <backup-file> --target HOST [--wait SECONDS]" >&2; exit 2; }
[ -f "$backup" ] || { echo "enclave-fw-rollback: backup $backup not found" >&2; exit 1; }

sleep "$wait_s"

if ping -c 1 -W 3 "$target" >/dev/null 2>&1; then
  echo "enclave-fw-rollback: $target reachable, keeping the current table"
  exit 0
fi

echo "enclave-fw-rollback: $target unreachable, restoring the previous table"
if [ -s "$backup" ]; then
  { printf 'table inet enclave\ndelete table inet enclave\n'; cat "$backup"; } | "$NFT" -f -
else
  printf 'table inet enclave\ndelete table inet enclave\n' | "$NFT" -f -
fi
