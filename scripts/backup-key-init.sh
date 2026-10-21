#!/usr/bin/env bash
# One-time: create the age key pair that encrypts Terraform state backups. Run by the
# operator, not by automation: it writes the macOS Keychain (service homelab):
#   backup-age-identity   the private key (AGE-SECRET-KEY-1...), needed to restore
#   backup-age-recipient  the public key (age1...), used by scripts/backup.sh
# The private key goes from age-keygen's stdout straight into the Keychain through
# `security -i` on stdin: never printed, never on disk, never in argv. Prints only "stored".
# Keep an offline copy of the identity; without it the tfstate backups cannot be read:
#   security find-generic-password -s homelab -a backup-age-identity -w
set -euo pipefail
{ set +x; } 2>/dev/null

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/keychain-lib.sh
source "$root/scripts/keychain-lib.sh"

die() { echo "backup-key-init: $*" >&2; exit 1; }

command -v age-keygen >/dev/null || die "age not found (brew install age)"
for a in backup-age-identity backup-age-recipient; do
  kc_exists "$a" && die "Keychain item $a already exists; refusing (existing backups may need it)"
done

# Keep only the secret-key line (age-keygen also writes comment lines).
store_identity_and_recipient() {
  local identity
  identity="$(grep '^AGE-SECRET-KEY-1')" || return 1
  printf '%s\n' "$identity" | kc_store_stdin backup-age-identity || return 1
  printf '%s\n' "$identity" | age-keygen -y | kc_store_stdin backup-age-recipient
}

age-keygen 2>/dev/null | store_identity_and_recipient ||
  die "storing the key failed; delete any half-written items and rerun:
  security delete-generic-password -s homelab -a backup-age-identity
  security delete-generic-password -s homelab -a backup-age-recipient"
echo stored
