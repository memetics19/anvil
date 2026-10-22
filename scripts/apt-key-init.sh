#!/usr/bin/env bash
# One-time: create the OpenPGP key that signs the apt repository (role apt_repo), and store
# it in Vault at kv/homelab/apt/signing:
#   private_key  the armored secret key (no passphrase: the VM signs unattended)
#   public_key   the armored public key, served as anvil.asc next to the repository
#   fingerprint  the key's fingerprint
# The key is made in a throwaway GNUPGHOME that is removed on exit, and goes to Vault as
# JSON on stdin: never printed, never in argv. Prints the fingerprint only.
# To rotate, delete kv/homelab/apt/signing, rerun this, and run the apt_repo role. Users
# then fetch the new anvil.asc once.
#   usage: scripts/apt-key-init.sh   (needs gpg, jq, vault and a Vault token)
set -euo pipefail
{ set +x; } 2>/dev/null

die() { echo "apt-key-init: $*" >&2; exit 1; }
for c in gpg jq vault; do command -v "$c" >/dev/null || die "needs $c"; done
path=homelab/apt/signing
if vault kv get -mount=kv "$path" >/dev/null 2>&1; then
  die "kv/$path already exists; refusing (installed systems trust that key)"
fi

GNUPGHOME=$(mktemp -d)
export GNUPGHOME
trap 'gpgconf --kill gpg-agent 2>/dev/null; rm -rf "$GNUPGHOME"' EXIT
chmod 700 "$GNUPGHOME"

gpg --batch --quiet --passphrase '' --quick-gen-key \
  'anvil apt repository <apt@anvil.invalid>' rsa4096 sign 3y
fpr=$(gpg --batch --with-colons --list-secret-keys | awk -F: '$1 == "fpr" {print $10; exit}')
[ -n "$fpr" ] || die "key generation failed"

# --rawfile reads through a file descriptor, so the key is not in jq's argv either.
jq -n --rawfile priv <(gpg --batch --armor --export-secret-keys "$fpr") \
  --rawfile pub <(gpg --batch --armor --export "$fpr") --arg fpr "$fpr" \
  '{private_key: $priv, public_key: $pub, fingerprint: $fpr}' |
  vault kv put -mount=kv "$path" - >/dev/null || die "cannot write kv/$path"
echo "stored, fingerprint $fpr"
