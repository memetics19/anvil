#!/usr/bin/env bash
# Back up Terraform state and a Vault Raft snapshot to ~/homelab-backups on the Mac.
# - tfstate holds site values: it is encrypted with age on the way in, so plaintext never
#   touches the disk (tfstate-YYYYMMDD-HHMM.json.age). The public key comes from Keychain
#   backup-age-recipient (scripts/backup-key-init.sh); BACKUP_AGE_RECIPIENT overrides it
#   (tests only). Read one back with scripts/backup-restore-tfstate.sh.
# - The Raft snapshot (vault-YYYYMMDD-HHMM.snap) is already encrypted by Vault's barrier.
# - Vaultwarden and Authentik: the newest nightly backup of each from its Ceph S3 bucket
#   (vaultwarden-backups: vaultwarden-YYYYMMDD-HHMMSS.tar.age, authentik-backups:
#   authentik-YYYYMMDD-HHMMSS.dump.age), encrypted on its VM to the same age recipient,
#   downloaded with that backup user's keys from Vault (kv/homelab/apps/vaultwarden-backup,
#   kv/homelab/identity/authentik-backup) passed to the aws CLI through its environment.
#   Each is skipped when Vault has no such keys (the service is not set up). They run after
#   the two above, so a failure here never loses them. Restore drill: make vaultwarden-drill.
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
part=
trap 'rm -f "$tf.partial" "$snap.partial" ${part:+"$part"}' EXIT

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

# --- nightly backups in the Ceph S3 gateway ---------------------------------------------------
# pull <name> <vault path> <bucket> <regex> <glob>: copies the newest object of the bucket
# whose name matches <regex> into ~/homelab-backups, then keeps the newest $keep files
# matching <glob> there.
pull() {
  local name=$1 path=$2 bucket=$3 pattern=$4 glob=$5 err json ak sk keys latest
  err=$(mktemp)
  if ! json=$(vault kv get -format=json -mount=kv "$path" 2>"$err"); then
    if grep -q '^No value found at ' "$err"; then
      rm -f "$err"
      echo "backup: no $name backup keys in Vault (kv/$path); $name skipped"
      return 0
    fi
    rm -f "$err"
    die "cannot read kv/$path"
  fi
  rm -f "$err"
  command -v aws >/dev/null || die "aws CLI not found (brew install awscli)"
  ak=$(printf '%s' "$json" | jq -r '.data.data.s3_access_key // empty')
  sk=$(printf '%s' "$json" | jq -r '.data.data.s3_secret_key // empty')
  unset json
  [ -n "$ak" ] && [ -n "$sk" ] || die "kv/$path lacks s3_access_key/s3_secret_key"
  # The keys only in the aws process's environment, never argv; no profile or config file.
  s3() {
    AWS_ACCESS_KEY_ID="$ak" AWS_SECRET_ACCESS_KEY="$sk" \
      AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_CONFIG_FILE=/dev/null AWS_REGION=us-east-1 \
      AWS_EC2_METADATA_DISABLED=true env -u AWS_PROFILE -u AWS_SESSION_TOKEN \
      aws --endpoint-url "http://${PVE_IP}:7480" "$@"
  }
  keys=$(s3 s3api list-objects-v2 --bucket "$bucket" --output json) ||
    die "listing s3://$bucket failed"
  latest=$(printf '%s' "$keys" | jq -r '.Contents[]?.Key' | { grep -E "$pattern" || true; } | sort -r | head -n 1)
  if [ -z "$latest" ]; then
    echo "backup: no $name backup in s3://$bucket yet"
    return 0
  fi
  if [ -f "$dir/$latest" ]; then
    echo "backup: $latest already in ~/homelab-backups"
  else
    part="$dir/$latest.partial"
    s3 s3api get-object --bucket "$bucket" --key "$latest" "$part" >/dev/null ||
      die "downloading $latest failed"
    [ "$(head -c 21 "$part")" = "age-encryption.org/v1" ] || die "$latest is not an age file"
    mv "$part" "$dir/$latest"
    part=
    chmod 600 "$dir/$latest"
    echo "backup: copied $latest to ~/homelab-backups"
  fi
  prune "$glob"
}

pull Vaultwarden homelab/apps/vaultwarden-backup vaultwarden-backups \
  '^vaultwarden-[0-9]{8}-[0-9]{6}\.tar\.age$' 'vaultwarden-*.tar.age'
pull Authentik homelab/identity/authentik-backup authentik-backups \
  '^authentik-[0-9]{8}-[0-9]{6}\.dump\.age$' 'authentik-*.dump.age'
