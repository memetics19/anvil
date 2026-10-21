#!/usr/bin/env bash
# Unseal Vault with 3 of the 5 unseal keys from the Keychain item vault-init-json.
# Keys go to the HTTP API on curl's stdin (never in argv, never printed).
set -euo pipefail
{ set +x; } 2>/dev/null

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"

die() { echo "vault-unseal: $*" >&2; exit 1; }
api() { curl -fsS --cacert "$VAULT_CACERT" "$@"; }

[ -n "${VAULT_IP:-}" ] || die "Keychain item vault-ip (service homelab) not found"
[ -s "$VAULT_CACERT" ] || die "CA certificate $VAULT_CACERT missing; run make vault first"

status="$(api "$VAULT_ADDR/v1/sys/seal-status")" || die "cannot reach Vault (Keychain vault-ip)"
[ "$(printf '%s' "$status" | jq -r '.initialized')" = true ] ||
  die "Vault is not initialised; the operator runs scripts/vault-init.sh first"
if [ "$(printf '%s' "$status" | jq -r '.sealed')" = false ]; then
  echo "already unsealed"
  exit 0
fi

init="$(security find-generic-password -s homelab -a vault-init-json -w 2>/dev/null)" ||
  die "Keychain item vault-init-json (service homelab) not found"
# `security -w` prints values with non-printable characters (e.g. newlines) as hex.
case $init in *[!0-9a-f]*) ;; *) init="$(printf '%s' "$init" | xxd -r -p)" ;; esac

keys=()
while IFS= read -r k; do keys+=("$k"); done < <(printf '%s' "$init" | jq -r '.unseal_keys_b64[0:3][]')
unset init
[ "${#keys[@]}" -eq 3 ] || die "vault-init-json does not hold at least 3 unseal keys"

sealed=true
for k in "${keys[@]}"; do
  # Base64 keys contain no quotes, so plain printf builds valid JSON.
  resp="$(printf '{"key":"%s"}' "$k" | api -X PUT --data-binary @- "$VAULT_ADDR/v1/sys/unseal")" ||
    die "unseal request failed"
  sealed="$(printf '%s' "$resp" | jq -r '.sealed')"
  [ "$sealed" = false ] && break
done
unset keys k

[ "$sealed" = false ] || die "still sealed after 3 keys (progress $(printf '%s' "$resp" | jq -r '"\(.progress)/\(.t)"'))"
echo "unsealed"
