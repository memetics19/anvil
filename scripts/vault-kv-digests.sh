#!/usr/bin/env bash
# vault-kv-digests.sh <path> [<mount>]: one line "<key> <sha256 of value>" per key stored at
# <mount>/<path> (KV v2, mount kv when none is given). Prints nothing when the path does not
# exist; any other Vault error fails. Values are never printed. Needs VAULT_ADDR/VAULT_TOKEN
# (scripts/env.sh).
set -euo pipefail
path=${1:?usage: vault-kv-digests.sh <path> [<mount>]}
mount=${2:-kv}
err=$(mktemp)
trap 'rm -f "$err"' EXIT
if ! out=$(vault kv get -format=json -mount="$mount" "$path" 2>"$err"); then
  grep -q '^No value found at ' "$err" && exit 0
  echo "vault-kv-digests: cannot read $mount/$path: $(head -c 300 "$err")" >&2
  exit 1
fi
printf '%s' "$out" | jq -r '.data.data | keys[]' | while IFS= read -r k; do
  printf '%s %s\n' "$k" "$(printf '%s' "$out" | jq -j --arg k "$k" '.data.data[$k]' | shasum -a 256 | cut -d' ' -f1)"
done
