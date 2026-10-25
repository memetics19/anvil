#!/usr/bin/env bash
# rotate.sh: new secrets, as code (anvil rotate).
#   radarr, sonarr, prowlarr (arr: all three): the app makes itself a new API key and
#   Prowlarr's links follow (role arr_stack, tag rotate), the keys go into Vault, then the
#   dashboard picks them up (tag homepage on every VM). Nothing is restarted.
# --check: Ansible's check mode, nothing changes.
# Usage: scripts/rotate.sh [--check] <secret>[,<secret>...]
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "rotate: $*" >&2; exit 1; }
known="radarr sonarr prowlarr"

check=false
[ "${1:-}" = --check ] && { check=true; shift; }
[ $# -eq 1 ] && [ -n "$1" ] || die "usage: scripts/rotate.sh [--check] <secret>[,<secret>...] (one of: $known, arr)"

apps=()
IFS=, read -ra asked <<<"$1"
for s in "${asked[@]}"; do
  case $s in
    arr) apps+=(radarr sonarr prowlarr) ;;
    radarr | sonarr | prowlarr) apps+=("$s") ;;
    *) die "no rotation for '$s'. These can rotate: $known, arr (all three)" ;;
  esac
done
list=$(printf '%s\n' "${apps[@]}" | awk '!seen[$0]++' | paste -sd, -)

# shellcheck source=/dev/null  # env.sh ends in a top-level return
source scripts/env.sh >/dev/null
[ -n "${TF_VAR_site_json:-}" ] || die "no site dict: scripts/env.sh could not load it"
# The VM that runs them: radarr's site.services entry names it as hosts.<vm>.ip.
host=$(jq -r '.services[] | select(.name == "radarr") | .host' <<<"$TF_VAR_site_json" |
  awk -F. '$1 == "hosts" { print $2 }')
[ -n "$host" ] || die "site.services has no radarr entry with host hosts.<vm>.ip"

if $check; then
  make -s vm HOST="$host" ARGS="--check --tags rotate -e arr_stack_rotate=$list"
  echo "rotate: check only, nothing changed"
  exit 0
fi
make -s vm HOST="$host" ARGS="--tags rotate -e arr_stack_rotate=$list"
echo "rotate: $list have new keys, in Vault. Now the dashboard"
make -s vms ARGS="--tags homepage" ||
  die "the dashboard did not take the new keys. The keys are rotated and in Vault: rerun make vms ARGS=\"--tags homepage\""
echo "rotate: done. anvil media reads the new keys from Vault"
