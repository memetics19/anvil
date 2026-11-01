#!/usr/bin/env bash
# arr-indexers.py (role arr_stack, tag arr_indexers) against a fake Prowlarr on localhost
# (tests/fixtures/fake_prowlarr.py): a missing indexer is added from the schema on its first
# address with its tags, a switched-off one switched on, a site that fails its test is
# reported and skipped, an unknown definition is reported, --check writes nothing, and the
# API key never reaches the output. Needs only python3.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v python3 >/dev/null || { echo "FAIL python3 missing"; exit 1; }

tmp=$(mktemp -d)
pid=""
trap '[ -n "$pid" ] && kill "$pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

key=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
printf '<Config><ApiKey>%s</ApiKey></Config>\n' "$key" >"$tmp/config.xml"
python3 tests/fixtures/fake_prowlarr.py "$tmp" "$tmp/port" & pid=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
url="http://127.0.0.1:$(cat "$tmp/port")"
policy=$(printf '{"url": "%s", "config_xml": "%s", "indexers": [%s], "apps": {"radarr": {"url": "%s", "config_xml": "%s", "off": ["RARBG", "Gone"]}}}' \
  "$url" "$tmp/config.xml" \
  '{"definition": "Knaben"}, {"definition": "1337x", "tags": ["cloudflare"]}, {"definition": "eztv"}, {"definition": "thepiratebay"}, {"definition": "limetorrents"}, {"definition": "nosuchsite"}, {"definition": "nyaasi", "base_url": "https://mirror.example/"}' \
  "$url" "$tmp/config.xml")
script=ansible/roles/arr_stack/files/arr-indexers.py

python3 "$script" --check "$policy" >"$tmp/check.out" 2>&1
check "--check says what it would add and switch on" \
  "grep -q 'Knaben: would add' '$tmp/check.out' && grep -q '1337x: would add (and tags cloudflare)' '$tmp/check.out' && grep -q 'LimeTorrents: would switch on' '$tmp/check.out'"
check "--check says it would move an indexer to its mirror and switch off a hand-added one" \
  "grep -q 'Nyaa.si: would move to https://mirror.example/' '$tmp/check.out' && grep -q 'radarr: RARBG: would switch off' '$tmp/check.out'"
check "--check writes nothing" "[ ! -e '$tmp/writes' ]"

python3 "$script" "$policy" >"$tmp/run.out" 2>&1
w=$tmp/writes
check "an indexer that is there and on is left alone" "grep -q 'The Pirate Bay: ok' '$tmp/run.out' && ! grep -q '\"name\": \"The Pirate Bay\"' '$w'"
check "a missing indexer is added, switched on, on its first address, in the first app profile" "python3 -c '
import json
ws = [json.loads(l) for l in open(\"$w\")]
k = [x[\"body\"] for x in ws if x[\"path\"] == \"indexer\" and x[\"body\"][\"definitionName\"] == \"Knaben\"][0]
assert k[\"enable\"] and k[\"appProfileId\"] == 7 and k[\"tags\"] == []
assert [f[\"value\"] for f in k[\"fields\"] if f[\"name\"] == \"baseUrl\"] == [\"https://knaben.example/\"]
'"
check "a missing tag is created and given to the indexer" "python3 -c '
import json
ws = [json.loads(l) for l in open(\"$w\")]
t = [x for x in ws if x[\"path\"] == \"tag\"][0][\"body\"]
assert t[\"label\"] == \"cloudflare\"
x = [x[\"body\"] for x in ws if x[\"path\"] == \"indexer\" and x[\"body\"][\"definitionName\"] == \"1337x\"][0]
assert x[\"tags\"] == [2]
'"
check "a switched-off indexer is switched on" "grep -q 'LimeTorrents: do: switched on' '$tmp/run.out' && grep -q '\"path\": \"indexer/2\"' '$w'"
check "a site that fails its test is reported and skipped, the run goes on" \
  "grep -q 'EZTV: skipped, its test failed (HTTP 400): Unable to connect to indexer' '$tmp/run.out' && grep -q 'not ready, the others are' '$tmp/run.out'"
check "an unknown definition is reported" "grep -q 'nosuchsite: no such definition' '$tmp/run.out'"
check "an indexer is moved to its mirror" "python3 -c '
import json
ws = [json.loads(l) for l in open(\"$w\")]
n = [x[\"body\"] for x in ws if x[\"path\"] == \"indexer/3\"][0]
assert [f[\"value\"] for f in n[\"fields\"] if f[\"name\"] == \"baseUrl\"] == [\"https://mirror.example/\"]
'"
check "a hand-added app indexer is switched off, saved without its test, never deleted" "python3 -c '
import json
ws = [json.loads(l) for l in open(\"$w\")]
r = [x for x in ws if x[\"path\"].startswith(\"v3/indexer/14\")]
assert len(r) == 1 and r[0][\"method\"] == \"PUT\" and \"forceSave=true\" in r[0][\"path\"]
b = r[0][\"body\"]; assert not (b[\"enableRss\"] or b[\"enableAutomaticSearch\"] or b[\"enableInteractiveSearch\"])
assert not [x for x in ws if x[\"method\"] == \"DELETE\"]
'"
check "an app indexer already off, or not named, is left alone" \
  "grep -q 'radarr: Gone: off' '$tmp/run.out' && ! grep -q 'v3/indexer/15' '$w' && ! grep -q 'v3/indexer/22' '$w'"
check "the API key is never printed" "! grep -q '$key' '$tmp/check.out' '$tmp/run.out'"

[ "$fail" = 0 ] && echo "PASS: arr indexers"
exit "$fail"
