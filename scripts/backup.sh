#!/usr/bin/env bash
# Back up Terraform state and a Vault Raft snapshot to ~/homelab-backups on the Mac.
# Both files hold site values or secrets: the directory is 700 and the files 600.
# Keeps the newest 30 of each kind. Needs VAULT_TOKEN (the snapshot API requires a token).
set -euo pipefail
{ set +x; } 2>/dev/null

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"

die() { echo "backup: $*" >&2; exit 1; }

keep=30
dir="$HOME/homelab-backups"
ts="$(date +%Y%m%d-%H%M)"

[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN not set (Keychain vault-init-json); Vault must be initialised"
[ -s "$VAULT_CACERT" ] || die "CA certificate $VAULT_CACERT missing; run make vault first"

umask 077
mkdir -p "$dir"
chmod 700 "$dir"

# Write to a temporary name first so a failed run never leaves a truncated "newest" file.
tf="$dir/tfstate-$ts.json"
terraform -chdir="$root/terraform" state pull >"$tf.partial" || { rm -f "$tf.partial"; die "terraform state pull failed"; }
[ -s "$tf.partial" ] || { rm -f "$tf.partial"; die "terraform state pull returned nothing"; }
mv "$tf.partial" "$tf"
chmod 600 "$tf"

snap="$dir/vault-$ts.snap"
vault operator raft snapshot save "$snap.partial" || { rm -f "$snap.partial"; die "vault snapshot failed"; }
mv "$snap.partial" "$snap"
chmod 600 "$snap"

# Names sort by time (YYYYMMDD-HHMM); delete all but the newest $keep of each kind.
prune() {
  local files=() i
  while IFS= read -r f; do files+=("$f"); done < <(find "$dir" -maxdepth 1 -type f -name "$1" | sort -r)
  for ((i = keep; i < ${#files[@]}; i++)); do rm -f "${files[i]}"; done
}
prune 'tfstate-*.json'
prune 'vault-*.snap'

echo "backup: wrote $(basename "$tf") and $(basename "$snap") in ~/homelab-backups"
