#!/usr/bin/env bash
# SC2015: ok never fails, so A && ok || bad_ is a plain if-else. SC2329: cleanup runs on EXIT.
# shellcheck disable=SC2015,SC2329
# The quality policy (role arr_stack, files/arr-quality.py) against a fake Sonarr and Radarr
# on localhost (tests/fixtures/fake_arr_quality.py):
#  - check mode changes nothing;
#  - the profile 1080p+ takes 1080p and 2160p, never 720p, SD, remuxes or disc images;
#  - 1080p is preferred: 2160p ranks below every 1080p quality, and the cutoff is the
#    lowest allowed quality, so whatever is taken is final;
#  - the 2160p minimum sizes are set, other definitions and profiles are left alone;
#  - a second run changes nothing, a profile edited by hand is put back;
#  - the role's tasks run through Ansible, and no key shows up in the output.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
repo=$PWD
script=$repo/ansible/roles/arr_stack/files/arr-quality.py

skip() { if [ -n "${CI:-}" ]; then echo "FAIL: cannot run in CI: $1"; exit 1; fi; echo "SKIP: $1"; exit 0; }
command -v python3 >/dev/null || skip "python3 missing"

tmp=$(mktemp -d)
pid=
cleanup() { [ -n "$pid" ] && { kill "$pid"; wait "$pid"; } 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }

for app in sonarr radarr; do
  mkdir -p "$tmp/$app"
  printf '<Config><ApiKey>%s</ApiKey></Config>\n' "$(python3 -c 'import secrets; print(secrets.token_hex(16))')" >"$tmp/$app/config.xml"
done
read -r ps pr < <(python3 -c '
import socket
s = [socket.socket() for _ in range(2)]
for x in s: x.bind(("127.0.0.1", 0))
print(*[x.getsockname()[1] for x in s])')
python3 tests/fixtures/fake_arr_quality.py "$tmp" "$ps" "$pr" &
pid=$!
for _ in $(seq 50); do
  python3 -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$pr" 2>/dev/null && break
  sleep 0.1
done

policy=$(python3 -c '
import json, sys
d, ps, pr = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({"profile": "1080p+", "min_resolution": 1080, "prefer_resolution": 1080,
                  "exclude": ["remux", "br-disk", "raw-hd"],
                  "min_sizes": {"WEBDL-2160p": 10, "WEBRip-2160p": 10},
                  "apps": {"sonarr": {"url": f"http://127.0.0.1:{ps}", "config_xml": f"{d}/sonarr/config.xml"},
                           "radarr": {"url": f"http://127.0.0.1:{pr}", "config_xml": f"{d}/radarr/config.xml"}}}))
' "$tmp" "$ps" "$pr")
# st <app> <python expression on s>: the fake's state
st() { python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$tmp/$1.json" "$2"; }
prof='next(p for p in s["profiles"] if p["name"]=="1080p+")'
allowed() { st "$1" "sorted((i.get(\"name\") or i[\"quality\"][\"name\"]) for i in ${prof}[\"items\"] if i[\"allowed\"])"; }

out=$(python3 "$script" --check "$policy")
grep -q "^sonarr: would create profile 1080p+" <<<"$out" && [ "$(st sonarr 's["writes"]')" = 0 ] && [ "$(st radarr 's["writes"]')" = 0 ] &&
  ok "check mode changes nothing" || bad_ "check mode: $out"

out=$(python3 "$script" "$policy")
[ "$(allowed sonarr)" = "['Bluray-1080p', 'HDTV-1080p', 'WEB 1080p', 'WEB 2160p']" ] &&
  ok "Sonarr 1080p+: 1080p and 2160p, no 720p, SD or remux" || bad_ "Sonarr allowed: $(allowed sonarr)"
[ "$(allowed radarr)" = "['Bluray-1080p', 'WEBDL-1080p', 'WEBDL-2160p']" ] &&
  ok "Radarr 1080p+: no remux, no BR-DISK" || bad_ "Radarr allowed: $(allowed radarr)"
[ "$(st sonarr "${prof}[\"cutoff\"]")" = 1003 ] && [ "$(st radarr "${prof}[\"cutoff\"]")" = 18 ] && [ "$(st sonarr "${prof}[\"upgradeAllowed\"]")" = True ] &&
  ok "cutoff is the lowest allowed quality (2160p now), so any grab is final" || bad_ "cutoff: $(st sonarr "${prof}[\"cutoff\"]") $(st radarr "${prof}[\"cutoff\"]")"
# ranked: the names of the allowed items, lowest first
ranked() { st "$1" "[(i.get(\"name\") or i[\"quality\"][\"name\"]) for i in ${prof}[\"items\"] if i[\"allowed\"]]"; }
[ "$(ranked sonarr)" = "['WEB 2160p', 'HDTV-1080p', 'WEB 1080p', 'Bluray-1080p']" ] &&
  [ "$(ranked radarr)" = "['WEBDL-2160p', 'WEBDL-1080p', 'Bluray-1080p']" ] &&
  ok "1080p preferred: 2160p ranks below every 1080p quality" || bad_ "ranking: $(ranked sonarr) $(ranked radarr)"
[ "$(st sonarr "len(${prof}[\"items\"])")" = 9 ] && ok "every quality is still in the profile" || bad_ "items lost"
[ "$(st sonarr '[d["minSize"] for d in s["defs"]]')" = "[4, 10, 10]" ] &&
  ok "2160p minimum 10 MB/min, 1080p untouched" || bad_ "sizes: $(st sonarr '[d["minSize"] for d in s["defs"]]')"
[ "$(st sonarr '[p["upgradeAllowed"] for p in s["profiles"] if p["name"]=="HD-1080p"]')" = "[False]" ] &&
  ok "other profiles are left alone" || bad_ "other profile changed"
grep -qF "$(sed -n 's:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p' "$tmp/sonarr/config.xml")" <<<"$out" && bad_ "a key is in the output" || ok "no key in the output"

w=$(st sonarr 's["writes"]')
out=$(python3 "$script" "$policy")
[ "$(st sonarr 's["writes"]')" = "$w" ] && grep -q "^arr-quality: 0 change(s)" <<<"$out" &&
  ok "a second run changes nothing" || bad_ "second run: $out"

python3 - "$tmp/sonarr.json" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
p = next(p for p in s["profiles"] if p["name"] == "1080p+")
for i in p["items"]:
    if (i.get("name") or i["quality"]["name"]) == "WEB 720p":
        i["allowed"] = True
open(sys.argv[1], "w").write(json.dumps(s))
PY
out=$(python3 "$script" "$policy")
grep -q "^sonarr: do: correct profile 1080p+" <<<"$out" && [ "$(allowed sonarr)" = "['Bluray-1080p', 'HDTV-1080p', 'WEB 1080p', 'WEB 2160p']" ] &&
  ok "720p added by hand is taken out again" || bad_ "correction: $out"

# The role's tasks through Ansible, against the same fake.
if command -v ansible-playbook >/dev/null; then
  cat >"$tmp/play.yml" <<'YAML'
- name: The quality policy against the fake apps
  hosts: localhost
  gather_facts: false
  tasks:
    - name: The quality tasks
      ansible.builtin.include_role:
        name: arr_stack
        tasks_from: quality
YAML
  vars=$(python3 -c '
import json, sys
d, ps, pr = sys.argv[1:]
print(json.dumps({"arr_stack_api_host": "127.0.0.1",
                  "arr_stack_api": {"sonarr": {"port": int(ps)}, "radarr": {"port": int(pr)}},
                  "arr_stack_config_xml_files": {a: f"{d}/{a}/config.xml" for a in ["sonarr", "radarr"]}}))' "$tmp" "$ps" "$pr")
  ANSIBLE_ROLES_PATH=$repo/ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_NOCOLOR=1 \
    ansible-playbook -i localhost, -c local -e "ansible_python_interpreter=$(command -v python3)" -e "$vars" "$tmp/play.yml" >"$tmp/out" 2>&1
  rc=$?
  [ $rc = 0 ] && grep -q "ok: profile 1080p+" "$tmp/out" && ok "the role's tasks run and find nothing to change" ||
    bad_ "role run (rc $rc): $(grep -E 'FAILED|fatal|ERROR' "$tmp/out" | head -3)"
else
  skip "ansible-playbook missing"
fi

exit $fail
