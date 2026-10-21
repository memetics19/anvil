#!/usr/bin/env bash
# Back up Terraform state and a Vault Raft snapshot to ~/homelab-backups on the Mac.
# - tfstate holds site values: it is encrypted with age on the way in, so plaintext never
#   touches the disk (tfstate-YYYYMMDD-HHMM.json.age). The public key comes from Keychain
#   backup-age-recipient (scripts/backup-key-init.sh); BACKUP_AGE_RECIPIENT overrides it
#   (tests only). Read one back with scripts/backup-restore-tfstate.sh.
# - The Raft snapshot (vault-YYYYMMDD-HHMM.snap) is already encrypted by Vault's barrier.
# Directory 700, files 600. Keeps the newest 30 of each kind. Needs VAULT_TOKEN.
set -euo pipefail
{ set +x; } 2>/dev/null

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"

die() { echo "backup: $*" >&2; exit 1; }

keep=30
dir="$HOME/homelab-backups"
ts="$(date +%Y%m%d-%H%M)"
tf="$dir/tfstate-$ts.json.age"
snap="$dir/vault-$ts.snap"

command -v age >/dev/null || die "age not found (brew install age)"
recipient="${BACKUP_AGE_RECIPIENT:-$(security find-generic-password -s homelab -a backup-age-recipient -w 2>/dev/null || true)}"
case $recipient in
  age1*) ;;
  *) die "no age recipient: Keychain item backup-age-recipient is missing; run scripts/backup-key-init.sh once" ;;
esac
[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN not set (Keychain vault-init-json); Vault must be initialised"
[ -s "$VAULT_CACERT" ] || die "CA certificate $VAULT_CACERT missing; run make vault first"

umask 077
mkdir -p "$dir"
chmod 700 "$dir"
# Partial files never survive a failed or interrupted run.
trap 'rm -f "$tf.partial" "$snap.partial"' EXIT

# Pass stdin through, failing when it is empty (an empty state is not a backup).
nonempty() { local first; IFS= read -r first || return 1; printf '%s\n' "$first"; cat; }
terraform -chdir="$root/terraform" state pull | nonempty | age -r "$recipient" >"$tf.partial" ||
  die "terraform state pull (empty?) or encryption failed"
mv "$tf.partial" "$tf"
chmod 600 "$tf"

vault operator raft snapshot save "$snap.partial" || die "vault snapshot failed"
mv "$snap.partial" "$snap"
chmod 600 "$snap"

# Names sort by time (YYYYMMDD-HHMM); delete all but the newest $keep of each kind.
prune() {
  local files=() i
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name "$1" | sort -r)
  for ((i = keep; i < ${#files[@]}; i++)); do rm -f "${files[i]}"; done
}
prune 'tfstate-*.json.age'
prune 'vault-*.snap'

echo "backup: wrote $(basename "$tf") and $(basename "$snap") in ~/homelab-backups"
