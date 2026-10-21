#!/usr/bin/env bash
# Decrypt a Terraform state backup to stdout (never to a file); default: the newest.
#   usage: scripts/backup-restore-tfstate.sh [~/homelab-backups/tfstate-YYYYMMDD-HHMM.json.age]
#   e.g.   scripts/backup-restore-tfstate.sh | jq .serial
# The age identity comes from Keychain backup-age-identity (scripts/backup-key-init.sh);
# BACKUP_AGE_IDENTITY_FILE overrides it (tests only).
set -euo pipefail
{ set +x; } 2>/dev/null

die() { echo "backup-restore-tfstate: $*" >&2; exit 1; }

dir="$HOME/homelab-backups"
file=${1:-}
if [ -z "$file" ]; then
  file="$(find "$dir" -maxdepth 1 -type f -name 'tfstate-*.json.age' | sort -r | head -n 1)"
  [ -n "$file" ] || die "no tfstate-*.json.age in ~/homelab-backups"
fi
[ -f "$file" ] || die "$file not found"

if [ -n "${BACKUP_AGE_IDENTITY_FILE:-}" ]; then
  age -d -i "$BACKUP_AGE_IDENTITY_FILE" "$file"
else
  # Process substitution: the identity reaches age through a pipe, not a file or argv.
  identity="$(security find-generic-password -s homelab -a backup-age-identity -w 2>/dev/null)" ||
    die "Keychain item backup-age-identity (service homelab) not found"
  age -d -i <(printf '%s\n' "$identity") "$file"
fi
