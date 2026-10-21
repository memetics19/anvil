#!/usr/bin/env bash
# Back up Terraform state and a Vault Raft snapshot to ~/homelab-backups on the Mac.
# - tfstate holds site values: it is encrypted with age on the way in, so plaintext never
#   touches the disk (tfstate-YYYYMMDD-HHMM.json.age). The public key comes from Keychain
#   backup-age-recipient (scripts/backup-key-init.sh); BACKUP_AGE_RECIPIENT overrides it
#   (tests only). Read one back with scripts/backup-restore-tfstate.sh.
# - The Raft snapshot (vault-YYYYMMDD-HHMM.snap) is already encrypted by Vault's barrier.
# - Vaultwarden: the newest nightly backup from the Ceph S3 bucket vaultwarden-backups
#   (vaultwarden-YYYYMMDD-HHMMSS.tar.age, encrypted on the apps VM to the same age
#   recipient), downloaded with the backup user's keys from Vault (kv/homelab/apps/
#   vaultwarden-backup) passed to the aws CLI through its environment. Skipped when Vault
#   has no such keys (no Vaultwarden); runs after the two above, so a failure here never
#   loses them. Restore drill: make vaultwarden-drill.
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
vw_part=
trap 'rm -f "$tf.partial" "$snap.partial" ${vw_part:+"$vw_part"}' EXIT

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

# --- Vaultwarden -----------------------------------------------------------------------------
vw_path=homelab/apps/vaultwarden-backup
vw_bucket=vaultwarden-backups
vw_pattern='^vaultwarden-[0-9]{8}-[0-9]{6}\.tar\.age$'
vw_err=$(mktemp)
if ! vw_json=$(vault kv get -format=json -mount=kv "$vw_path" 2>"$vw_err"); then
  if grep -q '^No value found at ' "$vw_err"; then
    rm -f "$vw_err"
    echo "backup: no Vaultwarden backup keys in Vault (kv/$vw_path); Vaultwarden skipped"
    exit 0
  fi
  rm -f "$vw_err"
  die "cannot read kv/$vw_path"
fi
rm -f "$vw_err"
command -v aws >/dev/null || die "aws CLI not found (brew install awscli)"
vw_ak=$(printf '%s' "$vw_json" | jq -r '.data.data.s3_access_key // empty')
vw_sk=$(printf '%s' "$vw_json" | jq -r '.data.data.s3_secret_key // empty')
unset vw_json
[ -n "$vw_ak" ] && [ -n "$vw_sk" ] || die "kv/$vw_path lacks s3_access_key/s3_secret_key"
# The keys only in the aws process's environment, never argv; no profile or config file.
vw_aws() {
  AWS_ACCESS_KEY_ID="$vw_ak" AWS_SECRET_ACCESS_KEY="$vw_sk" \
    AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null AWS_REGION=us-east-1 \
    AWS_EC2_METADATA_DISABLED=true env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
    aws --endpoint-url "http://${PVE_IP}:7480" "$@"
}
vw_keys=$(vw_aws s3api list-objects-v2 --bucket "$vw_bucket" --output json) ||
  die "listing s3://$vw_bucket failed"
vw_latest=$(printf '%s' "$vw_keys" | jq -r '.Contents[]?.Key' | { grep -E "$vw_pattern" || true; } | sort -r | head -n 1)
if [ -z "$vw_latest" ]; then
  echo "backup: no Vaultwarden backup in s3://$vw_bucket yet"
  exit 0
fi
if [ -f "$dir/$vw_latest" ]; then
  echo "backup: $vw_latest already in ~/homelab-backups"
else
  vw_part="$dir/$vw_latest.partial"
  vw_aws s3api get-object --bucket "$vw_bucket" --key "$vw_latest" "$vw_part" >/dev/null ||
    die "downloading $vw_latest failed"
  [ "$(head -c 21 "$vw_part")" = "age-encryption.org/v1" ] || die "$vw_latest is not an age file"
  mv "$vw_part" "$dir/$vw_latest"
  chmod 600 "$dir/$vw_latest"
  echo "backup: copied $vw_latest to ~/homelab-backups"
fi
prune 'vaultwarden-*.tar.age'
