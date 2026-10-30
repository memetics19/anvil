#!/usr/bin/env bash
# Every service name on the gateway answers over HTTPS from this machine: no lost
# connection, no server error. A name behind single sign-on must send a visitor who is not
# logged in to the login page (auth.<gateway domain>), not to the app.
source "$(dirname "$0")/lib.sh"
command -v curl >/dev/null || skip "curl missing"

gw=$(gateway_domain)
exempt=$(sed -n 's/^caddy_sso_exempt: *\[\(.*\)\]/\1/p' ansible/roles/caddy/defaults/main.yml | tr -d ' ')
# One line per enabled name: "<name> sso" or "<name> open", by the role's rules: an entry's
# own sso wins, else the exemption list. No auth route means no single sign-on at all.
routes=$(EXEMPT="$exempt" python3 -c '
import json, os
s = json.loads(os.environ["TF_VAR_site_json"])
exempt = set(os.environ["EXEMPT"].split(","))
on = [x for x in s.get("services", []) if x.get("name") and str(x.get("enabled", True)).lower() not in ("false", "no")]
sso_on = any(x["name"] == "auth" for x in on)
for x in on:
    sso = x["sso"] if "sso" in x else x["name"] not in exempt
    print(x["name"], "sso" if sso_on and str(sso).lower() not in ("false", "no") else "open")
')
[ -n "$routes" ] || { bad_ "the site lists gateway services"; done_ gateway; }

while read -r n mode; do
  # Code and redirect target only. The URL is never printed.
  read -r code location < <(curl -sS -o /dev/null --max-time 10 -w '%{http_code} %{redirect_url}\n' "https://$n.$gw/" 2>/dev/null || echo "000 -")
  if [ "$code" = 000 ]; then bad_ "$n answers (no connection)"; continue; fi
  if [ "$code" -ge 500 ]; then bad_ "$n answers ($code, a server error)"; continue; fi
  if [ "$mode" = open ]; then
    ok "$n answers ($code)"
  elif [[ "$code" =~ ^30[1278]$ ]] && [[ "$location" == "https://auth.$gw/"* ]]; then
    ok "$n is behind single sign-on ($code to the login page)"
  else
    bad_ "$n is behind single sign-on (got $code, not a redirect to the login page)"
  fi
done <<<"$routes"
done_ gateway
