#!/usr/bin/env bash
# One-time Vault initialisation. Run by the operator, not by automation: it writes the
# macOS Keychain (service homelab, account vault-init-json).
#
# `vault operator init` output (5 unseal keys, threshold 3, root token) goes straight from
# the CLI's stdout into the Keychain. It is never printed, written to a file, or passed as
# a command-line argument: the Keychain write is a command line fed to `security -i` on
# stdin by the printf builtin, so the value never appears in any process's argv.
set -euo pipefail
{ set +x; } 2>/dev/null

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"

kc_service=homelab
kc_account=vault-init-json

die() { echo "vault-init: $*" >&2; exit 1; }

# Quote a value for one `security -i` command line: wrap in double quotes, escape \ and ".
kc_quote() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

# Store stdin as the password of a Keychain item without putting it in argv, then read it
# back and compare. Never overwrites an existing item (no -U).
kc_store_stdin() {
  local account=$1 value back
  value="$(cat)"
  [ -n "$value" ] || { echo "vault-init: nothing to store" >&2; return 1; }
  printf 'add-generic-password -s %s -a %s -w %s\n' \
    "$kc_service" "$account" "$(kc_quote "$value")" | security -i >/dev/null 2>&1 || return 1
  back="$(security find-generic-password -s "$kc_service" -a "$account" -w 2>/dev/null)" || return 1
  [ "$back" = "$value" ]
}

# One-line JSON (`security -w` prints multi-line values hex-encoded). Deliberately no
# shape check here: storing an unexpected shape beats losing the only copy.
init_json_compact() { jq -c .; }

command -v vault >/dev/null || die "vault CLI not found (brew install hashicorp/tap/vault)"
command -v jq >/dev/null || die "jq not found"
[ -n "${VAULT_IP:-}" ] || die "Keychain item vault-ip (service homelab) not found"
[ -s "$VAULT_CACERT" ] || die "CA certificate $VAULT_CACERT missing; run make vault first"

if security find-generic-password -s "$kc_service" -a "$kc_account" >/dev/null 2>&1; then
  die "Keychain item $kc_account already exists; refusing (it may hold the only copy of the keys)"
fi

init_state="$(curl -fsS --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/init" | jq -r '.initialized')" ||
  die "cannot reach Vault at $VAULT_ADDR"
case $init_state in
  false) ;;
  true) die "Vault is already initialised; refusing" ;;
  *) die "unexpected answer from $VAULT_ADDR/v1/sys/init" ;;
esac

# Prove the Keychain write path (quoting included) with a throwaway item before init,
# because the init output cannot be produced a second time.
probe_account=vault-init-probe
security delete-generic-password -s "$kc_service" -a "$probe_account" >/dev/null 2>&1 || true
printf '%s' '{"probe":"a \"quoted\" \\ value"}' | kc_store_stdin "$probe_account" ||
  die "Keychain write test failed (is the login keychain unlocked?); Vault was NOT initialised"
security delete-generic-password -s "$kc_service" -a "$probe_account" >/dev/null 2>&1 || true

if ! vault operator init -key-shares=5 -key-threshold=3 -format=json |
  init_json_compact | kc_store_stdin "$kc_account"; then
  cat >&2 <<'EOF'
vault-init: FAILED after `vault operator init` may have run; the keys were not stored.
Vault holds no data yet, so reset it, remove any half-written Keychain item, and rerun:
  security delete-generic-password -s homelab -a vault-init-json
  ssh ubuntu@<vault-ip> 'sudo systemctl stop vault && sudo find /opt/vault/data -mindepth 1 -delete && sudo systemctl start vault'
EOF
  exit 1
fi

security find-generic-password -s "$kc_service" -a "$kc_account" -w |
  jq -e '(.unseal_keys_b64 | length) == 5 and (.root_token | length) > 0' >/dev/null ||
  echo "vault-init: warning: stored init output does not have 5 keys and a root token; inspect it" >&2

cat <<EOF
initialized; keys stored in Keychain (service $kc_service, account $kc_account)

Keep an offline paper copy (Vault cannot be unsealed without 3 of the 5 keys). Print them
when you are ready to write them down, then clear the terminal:
  security find-generic-password -s $kc_service -a $kc_account -w | jq -r '.unseal_keys_b64[]'
  security find-generic-password -s $kc_service -a $kc_account -w | jq -r '.root_token'
Next: make vault-unseal
EOF
