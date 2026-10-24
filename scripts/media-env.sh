#!/usr/bin/env bash
# media-env.sh: Radarr's and Sonarr's addresses and API keys as one JSON object on stdout,
# for `anvil media`. The addresses come from site.services (name radarr and sonarr), the
# keys from kv/homelab/<host>/arr (written by the arr_stack role). The keys only ever go
# through pipes and to stdout, never on a command line: run this into a pipe, not a terminal.
#   {"radarr": {"url": "http://<ip>:7878", "key": "..."}, "sonarr": {...}}
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null  # env.sh ends in a top-level return
source scripts/env.sh >/dev/null
if [ -z "${TF_VAR_site_json:-}" ]; then
  # site-source.sh says why (Vault unreachable, no Keychain copy, ...). It prints no values.
  reason=$(scripts/site-source.sh 2>&1 >/dev/null | tail -n 1)
  echo "media-env: no site dict${reason:+: $reason}" >&2
  exit 1
fi
[ -t 1 ] && { echo "media-env: refusing to print API keys to a terminal: pipe the output" >&2; exit 2; }

# The VM that runs Radarr: its site.services entry names the address as hosts.<vm>.ip.
host=$(jq -r 'env.TF_VAR_site_json | fromjson | .services[] | select(.name == "radarr") | .host' <<<'null' |
  awk -F. '$1 == "hosts" { print $2 }')
[ -n "$host" ] || { echo "media-env: site.services has no radarr entry with host hosts.<vm>.ip" >&2; exit 1; }

vault kv get -format=json -mount=kv "homelab/$host/arr" | jq -ce '
  (env.TF_VAR_site_json | fromjson) as $s
  | .data.data as $k
  | def url($n): ($s.services[] | select(.name == $n)) as $v
      | "\($v.scheme // "http")://\($s | getpath($v.host | split(".")))" + ":\($v.port)";
  { radarr: {url: url("radarr"), key: $k.radarr_api_key},
    sonarr: {url: url("sonarr"), key: $k.sonarr_api_key} }
  | select(.radarr.key and .sonarr.key)' ||
  { echo "media-env: kv/homelab/$host/arr has no radarr_api_key or sonarr_api_key (make vm HOST=$host ARGS=\"--tags homepage\")" >&2; exit 1; }
