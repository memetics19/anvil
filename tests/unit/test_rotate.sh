#!/usr/bin/env bash
# SC2015: ok never fails, so A && ok || bad_ is a plain if-else. SC2329: cleanup runs on EXIT.
# shellcheck disable=SC2015,SC2329
# anvil rotate (role arr_stack, tasks/rotate.yml) against a fake Radarr, Sonarr and
# Prowlarr on localhost (tests/fixtures/fake_arr.py):
#  - radarr: only Radarr's key changes, and Prowlarr's Radarr application gets it;
#  - prowlarr: only Prowlarr's key changes, and a forced sync pushes it to the indexers;
#  - check mode changes nothing; an unknown app stops before any call;
#  - no key ever shows up in Ansible's output;
#  - scripts/rotate.sh refuses an unknown secret before it loads anything.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
repo=$PWD

skip() { if [ -n "${CI:-}" ]; then echo "FAIL: cannot run in CI: $1"; exit 1; fi; echo "SKIP: $1"; exit 0; }
command -v ansible-playbook >/dev/null || skip "ansible-playbook missing"
command -v python3 >/dev/null || skip "python3 missing"

tmp=$(mktemp -d)
pid=
cleanup() { [ -n "$pid" ] && { kill "$pid"; wait "$pid"; } 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }

for app in radarr sonarr prowlarr; do
  mkdir -p "$tmp/arr/$app/config"
  printf '<Config>\n  <Port>1</Port>\n  <ApiKey>%s</ApiKey>\n</Config>\n' "$(python3 -c 'import secrets; print(secrets.token_hex(16))')" \
    >"$tmp/arr/$app/config/config.xml"
done
key() { sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$tmp/arr/$1/config/config.xml"; }
state() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$tmp/arr/state.json" "$1"; }

read -r p_radarr p_sonarr p_prowlarr < <(python3 -c '
import socket
s = [socket.socket() for _ in range(3)]
for x in s: x.bind(("127.0.0.1", 0))
print(*[x.getsockname()[1] for x in s])')
python3 tests/fixtures/fake_arr.py "$tmp/arr" "$p_radarr" "$p_sonarr" "$p_prowlarr" &
pid=$!
for _ in $(seq 50); do
  python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$p_prowlarr" 2>/dev/null && break
  sleep 0.1
done

cat >"$tmp/play.yml" <<'YAML'
- name: Rotate against the fake apps
  hosts: localhost
  gather_facts: false
  tasks:
    - name: The rotate tasks
      ansible.builtin.include_role:
        name: arr_stack
        tasks_from: rotate
YAML
vars=$(python3 -c '
import json, sys
d, r, s, p = sys.argv[1], *map(int, sys.argv[2:])
print(json.dumps({
  "arr_stack_api_host": "127.0.0.1",
  "arr_stack_api": {"radarr": {"port": r, "version": "v3"}, "sonarr": {"port": s, "version": "v3"},
                    "prowlarr": {"port": p, "version": "v1"}},
  "arr_stack_config_xml_files": {a: f"{d}/{a}/config/config.xml" for a in ["sonarr", "radarr", "prowlarr"]}}))
' "$tmp/arr" "$p_radarr" "$p_sonarr" "$p_prowlarr")

# play <apps> [extra args]: runs the tasks, output in $tmp/out (appended to $tmp/all)
play() {
  local apps=$1
  shift
  ANSIBLE_ROLES_PATH=$repo/ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
    ansible-playbook -i localhost, -c local -e "ansible_python_interpreter=$(command -v python3)" \
    -e "$vars" -e "arr_stack_rotate=$apps" "$@" "$tmp/play.yml" >"$tmp/out" 2>&1
  local rc=$?
  cat "$tmp/out" >>"$tmp/all"
  return $rc
}

r0=$(key radarr) s0=$(key sonarr) p0=$(key prowlarr)
all_keys=("$r0" "$s0" "$p0")

play radarr --check && [ "$(key radarr)" = "$r0" ] && [ "$(state 's["applications"][0]["fields"][2]["value"]')" = "$r0" ] &&
  ok "check mode changes nothing" || bad_ "check mode changed something: $(tail -5 "$tmp/out")"

if play radarr; then
  r1=$(key radarr)
  all_keys+=("$r1")
  [ "$r1" != "$r0" ] && [ "$(key sonarr)" = "$s0" ] && [ "$(key prowlarr)" = "$p0" ] &&
    ok "radarr: only Radarr's key changes" || bad_ "radarr: keys after: $(key sonarr | cut -c1-4)..."
  [ "$(state 's["applications"][0]["fields"][2]["value"]')" = "$r1" ] &&
    [ "$(state 's["applications"][1]["fields"][2]["value"]')" = "$s0" ] &&
    [ "$(state 's["applications"][0]["fields"][1]["value"]')" = "http://radarr" ] &&
    ok "radarr: Prowlarr's Radarr application has the new key, the rest as it was" ||
    bad_ "radarr: Prowlarr's applications not updated"
  [ "$(state 'len(s["syncs"])')" = 0 ] && ok "radarr: no indexer sync" || bad_ "radarr: an indexer sync ran"
else
  bad_ "radarr: the play failed: $(grep -E 'FAILED|fatal' "$tmp/out" | head -3)"
fi

if play prowlarr; then
  p1=$(key prowlarr)
  all_keys+=("$p1")
  [ "$p1" != "$p0" ] && [ "$(key sonarr)" = "$s0" ] && ok "prowlarr: only Prowlarr's key changes" || bad_ "prowlarr: keys"
  [ "$(state 's["syncs"]')" = "[{'name': 'ApplicationIndexerSync', 'forceSync': True}]" ] &&
    [ "$(state 's["indexer_key"]["sonarr"]')" = "$p1" ] &&
    ok "prowlarr: a forced sync pushes the new key to the indexers" || bad_ "prowlarr: no forced sync"
else
  bad_ "prowlarr: the play failed: $(grep -E 'FAILED|fatal' "$tmp/out" | head -3)"
fi

before=$(cat "$tmp"/arr/*/config/config.xml)
! play jellyfin && grep -q "arr_stack_rotate: one or more of" "$tmp/out" && [ "$(cat "$tmp"/arr/*/config/config.xml)" = "$before" ] &&
  ok "an unknown app stops before any call" || bad_ "an unknown app was not refused"

leaked=0
for k in "${all_keys[@]}"; do grep -qF "$k" "$tmp/all" && leaked=1; done
[ "$leaked" = 0 ] && ok "no key in Ansible's output" || bad_ "a key shows up in Ansible's output"

out=$(scripts/rotate.sh vault 2>&1) && bad_ "rotate.sh accepted vault"
grep -q "no rotation for 'vault'" <<<"$out" && ok "rotate.sh refuses an unknown secret" ||
  bad_ "rotate.sh: $out"

exit $fail
