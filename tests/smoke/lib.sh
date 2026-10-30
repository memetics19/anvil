# Shared by the smoke tests: read-only checks against the live lab. Sourced, not run.
# The site dict comes from scripts/env.sh (make test-smoke sources it) and is never printed.
# Output names services and hosts, never an address.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
skip() { echo "SKIP: $1"; exit 0; }
done_() { [ "$fail" = 0 ] && echo "PASS: $1"; exit "$fail"; }

[ -n "${TF_VAR_site_json:-}" ] || skip "needs the lab: run make test-smoke (it reads the site from Vault)"

# site <python expression over s, the site dict>: prints the value, empty when it is missing.
site() {
  python3 -c '
import json, os, sys
s = json.loads(os.environ["TF_VAR_site_json"])
try:
    v = eval(sys.argv[1], {"s": s})
except (KeyError, IndexError, TypeError):
    v = ""
if isinstance(v, (list, tuple)):
    print("\n".join(str(x) for x in v))
elif v is not None:
    print(v)
' "$1"
}

# The gateway's domain, as ansible/inventory/group_vars/all/gateway.yml builds it.
gateway_domain() {
  local sub domain
  sub=$(site 's.get("gateway", {}).get("subdomain") or ""')
  domain=$(site 's["domain"]')
  if [ -n "$sub" ]; then echo "$sub.$domain"; else echo "$domain"; fi
}

# smoke_play <playbook>: runs a read-only playbook from tests/smoke with --check, so even a
# mistake in it cannot change a host. Prints Ansible's output only when it fails.
smoke_play() {
  local log
  log=$(mktemp)
  if (cd ansible && ansible-playbook --check "../tests/smoke/$1") >"$log" 2>&1; then
    rm -f "$log"
    return 0
  fi
  # One line per problem: "<host>: <message>". Anything else that failed, as Ansible said it.
  sed -nE \
    -e 's/^fatal: \[([^]]+)\]: [A-Z!]+ => .*"msg": "([^"]*)".*/  \1: \2/p' \
    -e '/^fatal: .*"msg"/d' \
    -e 's/^(fatal|failed): \[([^]]+)\].*/  \2: failed, run the playbook by hand for the details/p' \
    -e 's/^(ERROR!.*)/  \1/p' "$log" | sort -u
  rm -f "$log"
  return 1
}
