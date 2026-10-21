#!/usr/bin/env bash
# Copy the site dict from the Keychain (account site-bootstrap, YAML with a top-level
# `site` key) into Vault at kv/homelab/site as {"site": {...}} (KV v2, mount kv; enabled
# here if missing). Values travel only through pipes: never argv, never printed.
# Idempotent. Refuses to replace a different existing value unless --force.
# Prints only "written" or "unchanged".
#   usage: scripts/site-to-vault.sh [--force]
set -euo pipefail
{ set +x; } 2>/dev/null

die() { echo "site-to-vault: $*" >&2; exit 1; }

force=false
case ${1:-} in
  --force) force=true ;;
  "") ;;
  *) die "usage: $0 [--force]" ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"

[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN not set (Keychain vault-init-json); initialise Vault first"

# YAML on stdin -> canonical JSON {"site": ...} (sorted keys, one line).
# python3 with PyYAML, else the system Ruby (Psych is in its stdlib), as in env.sh.
site_yaml_to_json() {
  local y; y="$(cat)"
  {
    # shellcheck disable=SC2016  # the $stdin below is Ruby, not shell
    printf '%s' "$y" | python3 -c 'import json,sys,yaml; print(json.dumps({"site": yaml.safe_load(sys.stdin)["site"]}))' 2>/dev/null ||
      printf '%s' "$y" | ruby -ryaml -rjson -e 'puts JSON.generate({"site" => YAML.safe_load($stdin.read)["site"]})' 2>/dev/null
  } | jq -S -c .
}
digest() { shasum -a 256 | cut -d' ' -f1; }

# KV v2 at kv/.
mounts="$(vault secrets list -format=json)" || die "cannot list secrets engines"
kv="$(printf '%s' "$mounts" | jq -r 'if ."kv/" == null then "" else "\(."kv/".type) \(."kv/".options.version // "1")" end')"
case $kv in
  "") vault secrets enable -path=kv -version=2 kv >/dev/null || die "cannot enable KV v2 at kv/" ;;
  "kv 2") ;;
  *) die "kv/ is mounted but is not KV v2 ($kv)" ;;
esac

v="$(security find-generic-password -s homelab -a site-bootstrap -w 2>/dev/null)" ||
  die "Keychain item site-bootstrap (service homelab) not found"
# `security -w` prints multi-line values hex-encoded.
case $v in *[!0-9a-f]*) ;; *) v="$(printf '%s' "$v" | xxd -r -p)" ;; esac
want="$(printf '%s' "$v" | site_yaml_to_json)" || die "site-bootstrap is not YAML with a top-level site dict"
unset v
printf '%s' "$want" | jq -e '.site.hosts | type == "object"' >/dev/null ||
  die "site-bootstrap has no site.hosts dict"
want_sum="$(printf '%s' "$want" | digest)"

if have="$(vault kv get -format=json -mount=kv homelab/site 2>/dev/null)"; then
  have="$(printf '%s' "$have" | jq -S -c '.data.data')"
else
  err="$(vault kv get -mount=kv homelab/site 2>&1 >/dev/null || true)"
  case $err in
    *"No value found"*) have=null ;;
    *) die "cannot read kv/homelab/site" ;;
  esac
fi

if [ "$have" != null ]; then
  if [ "$(printf '%s' "$have" | digest)" = "$want_sum" ]; then
    echo unchanged
    exit 0
  fi
  $force || die "kv/homelab/site differs from Keychain site-bootstrap; rerun with --force to replace it"
fi

printf '%s' "$want" | vault kv put -mount=kv homelab/site - >/dev/null || die "write failed"
back="$(vault kv get -format=json -mount=kv homelab/site | jq -S -c '.data.data')" || die "read-back failed"
[ "$(printf '%s' "$back" | digest)" = "$want_sum" ] || die "read-back does not match what was written"
echo written
