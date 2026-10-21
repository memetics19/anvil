#!/usr/bin/env bash
# Decide where the site dict comes from: "vault" or "keychain". Fails closed.
#   HOMELAB_SITE_SOURCE=keychain  operator override: use the Keychain copy (e.g. to repair Vault)
#   HOMELAB_SITE_SOURCE=vault     require Vault
#   no VAULT_TOKEN                keychain (Vault not initialised yet)
#   kv/homelab/site absent        keychain (not loaded yet; make site-to-vault)
#   any other Vault error         error, unless --allow-keychain-fallback (then keychain + warning)
# Output: by default just the source on stdout; warnings and errors on stderr, exit 1 on
# error. With --line (for Ansible, which hides a lookup's stderr): one line
# "<vault|keychain|error> [note]" and exit 0.
# Expects VAULT_ADDR / VAULT_CACERT / VAULT_TOKEN in the environment (scripts/env.sh).
# Prints no site values and no addresses.
set -euo pipefail
{ set +x; } 2>/dev/null

fallback=false line=false
for a in "$@"; do
  case $a in
    --allow-keychain-fallback) fallback=true ;;
    --line) line=true ;;
    *) echo "usage: $0 [--allow-keychain-fallback] [--line]" >&2; exit 2 ;;
  esac
done

# result <vault|keychain|error> [note]
result() {
  local kind=$1 note=${2:-}
  if $line; then
    echo "$kind${note:+ $note}"
    exit 0
  fi
  case $kind in
    error) echo "site-source: $note" >&2; exit 1 ;;
    *) [ -z "$note" ] || echo "site-source: warning: $note" >&2; echo "$kind"; exit 0 ;;
  esac
}

case ${HOMELAB_SITE_SOURCE:-} in
  keychain) result keychain ;;
  vault | "") ;;
  *) result error "HOMELAB_SITE_SOURCE must be vault or keychain" ;;
esac

if [ -z "${VAULT_TOKEN:-}" ]; then
  [ "${HOMELAB_SITE_SOURCE:-}" = vault ] && result error "HOMELAB_SITE_SOURCE=vault but VAULT_TOKEN is not set"
  result keychain
fi

if err="$(VAULT_CLIENT_TIMEOUT=5 VAULT_MAX_RETRIES=0 vault kv get -mount=kv homelab/site 2>&1 >/dev/null)"; then
  result vault
fi
case $err in
  *"No value found"*)
    [ "${HOMELAB_SITE_SOURCE:-}" = vault ] && result error "kv/homelab/site is not in Vault (make site-to-vault)"
    result keychain ;;
  *[Ss]ealed*) why="Vault is sealed (make vault-unseal)" ;;
  *"permission denied"* | *"403"*) why="the Vault token was rejected" ;;
  *"command not found"*) why="the vault CLI is missing" ;;
  *) why="Vault (Keychain vault-ip) is unreachable or returned an error" ;;
esac
$fallback && result keychain "$why; using the Keychain copy of the site dict"
result error "cannot read kv/homelab/site: $why. To use the Keychain copy deliberately, set HOMELAB_SITE_SOURCE=keychain."
