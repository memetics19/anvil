#!/usr/bin/env bash
# Refresh the Keychain bootstrap copy of the site dict from Vault (ruling: Vault is canonical).
# Reads kv/homelab/site and writes Keychain item site-bootstrap (service homelab) as one-line
# YAML in flow style ({"site": {...}}, which is also JSON), so `security -w` returns it as is.
# Values travel only through pipes and the `security -i` stdin: never argv, never printed.
# Prints only "updated" or "unchanged". Run by the operator; refuses without --yes.
#   usage: scripts/site-to-keychain.sh --yes
set -euo pipefail
{ set +x; } 2>/dev/null

die() { echo "site-to-keychain: $*" >&2; exit 1; }

[ "${1:-}" = --yes ] || die "usage: $0 --yes  (replaces Keychain site-bootstrap with Vault kv/homelab/site)"

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"
# shellcheck source=scripts/keychain-lib.sh
source "$root/scripts/keychain-lib.sh"
account=site-bootstrap

[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN not set (Keychain vault-init-json)"

want="$(vault kv get -format=json -mount=kv homelab/site 2>/dev/null |
  jq -S -c '{site: .data.data.site} | select(.site | type == "object")')" ||
  die "cannot read kv/homelab/site"
[ -n "$want" ] || die "kv/homelab/site holds no site dict"
digest() { shasum -a 256 | cut -d' ' -f1; }
want_sum="$(printf '%s' "$want" | digest)"

# The current Keychain copy, as canonical JSON (empty when missing or unreadable).
# `security -w` prints multi-line values hex-encoded.
have=
if v="$(security find-generic-password -s "$kc_service" -a "$account" -w 2>/dev/null)"; then
  case $v in *[!0-9a-f]*) ;; *) v="$(printf '%s' "$v" | xxd -r -p)" ;; esac
  have="$(printf '%s' "$v" |
    python3 -c 'import json,sys,yaml; print(json.dumps({"site": yaml.safe_load(sys.stdin)["site"]}))' 2>/dev/null |
    jq -S -c . 2>/dev/null)" || have=
  unset v
fi
if [ -n "$have" ] && [ "$(printf '%s' "$have" | digest)" = "$want_sum" ]; then
  echo unchanged
  exit 0
fi

# -U updates the existing item in place.
printf 'add-generic-password -U -s %s -a %s -w %s\n' \
  "$kc_service" "$account" "$(kc_quote "$want")" | security -i >/dev/null 2>&1 ||
  die "Keychain write failed"
back="$(security find-generic-password -s "$kc_service" -a "$account" -w 2>/dev/null)" ||
  die "Keychain read-back failed"
[ "$(printf '%s' "$back" | jq -S -c . 2>/dev/null | digest)" = "$want_sum" ] ||
  die "Keychain read-back does not match Vault"
echo updated
