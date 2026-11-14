#!/usr/bin/env bash
# youtube-env.sh: Pinchflat's address as one JSON object on stdout, for `anvil youtube`. It is
# the app's direct lab address (hosts.<vm>.ip and the port of the site.services entry
# youtube), not the gateway name: the gateway puts single sign-on in front of it, which a
# command line client cannot pass. The port guard admits the operator's own devices
# (site.admin_sources, site.admin_vpn_sources). Pinchflat has no login of its own, so there
# is no secret here.
#   {"url": "http://<lab ip>:8945"}
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null  # env.sh ends in a top-level return
source scripts/env.sh >/dev/null
if [ -z "${TF_VAR_site_json:-}" ]; then
  # site-source.sh says why (Vault unreachable, no Keychain copy, ...). It prints no values.
  reason=$(scripts/site-source.sh 2>&1 >/dev/null | tail -n 1)
  echo "youtube-env: no site dict${reason:+: $reason}" >&2
  exit 1
fi
jq -cne '
  (env.TF_VAR_site_json | fromjson) as $s
  | ([$s.services[] | select(.name == "youtube")] | first) as $v
  | if $v == null then error("site.services has no youtube entry") else . end
  | ($s | getpath($v.host | split("."))) as $ip
  | if ($ip | type) != "string" then error("site.services youtube: \($v.host) is not an address") else . end
  | {url: "http://\($ip):\($v.port)"}' 2> >(sed 's/^jq: error[^:]*: /youtube-env: /' >&2)
