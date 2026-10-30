#!/usr/bin/env bash
# Pi-hole on the apps VM answers for the whole home: every gateway name points at the
# gateway, a public name resolves through the upstream, and an ad domain is blocked.
source "$(dirname "$0")/lib.sh"
command -v dig >/dev/null || skip "dig missing"

dns=$(site 's["hosts"]["apps"]["home_ip"]')
[ -n "$dns" ] || skip "site.hosts.apps.home_ip is not set (no Pi-hole for the home)"
gw=$(gateway_domain)
ask() { dig +short +time=3 +tries=2 "@$dns" "$1" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1; }

names=$(site '[x["name"] for x in s.get("services", []) if x.get("name") and str(x.get("enabled", True)).lower() not in ("false", "no")]')
wrong=()
for n in $names; do [ "$(ask "$n.$gw")" = "$dns" ] || wrong+=("$n"); done
if [ "${#wrong[@]}" -eq 0 ]; then
  ok "every gateway name ($(wc -w <<<"$names" | tr -d ' ')) points at the gateway"
else
  bad_ "these gateway names do not point at the gateway: ${wrong[*]}"
fi

if [ -n "$(ask example.com)" ]; then ok "a public name resolves"; else bad_ "a public name resolves (the upstream)"; fi

blocked=$(ask doubleclick.net)
if [ -z "$blocked" ] || [ "$blocked" = 0.0.0.0 ]; then ok "an ad domain is blocked"; else bad_ "an ad domain is blocked"; fi
done_ dns
