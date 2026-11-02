#!/usr/bin/env bash
# arr-bazarr.py (role arr_stack, tag arr_subtitles) against a fake Bazarr, Sonarr and Radarr
# (tests/fixtures/fake_bazarr.py): Bazarr is connected to both apps with their keys, English
# is switched on with an English profile that new and unprofiled series and movies get, the
# OpenSubtitles.com account comes from stdin and is never printed, providers added by hand
# are kept, the apps import .srt files, --check writes nothing, and a second run changes
# nothing. The keys are random each run.
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
hex() { python3 -c 'import secrets; print(secrets.token_hex(16))'; }

bkey=$(hex); skey=$(hex); rkey=$(hex)
printf 'auth:\n  type: null\n  apikey: %s\ngeneral:\n  port: 6767\n' "$bkey" >"$tmp/config.yaml"
printf '<Config><ApiKey>%s</ApiKey></Config>\n' "$skey" >"$tmp/sonarr.xml"
printf '<Config><ApiKey>%s</ApiKey></Config>\n' "$rkey" >"$tmp/radarr.xml"
python3 tests/fixtures/fake_bazarr.py "$tmp" "$tmp/port" & pid=$!
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
url="http://127.0.0.1:$(cat "$tmp/port")"
policy=$(printf '{"url": "%s", "config_yaml": "%s", "sonarr": {"host": "sonarr", "port": 8989, "url": "%s", "config_xml": "%s"}, "radarr": {"host": "radarr", "port": 7878, "url": "%s", "config_xml": "%s"}, "languages": ["en"], "profile": "English"}' \
  "$url" "$tmp/config.yaml" "$url" "$tmp/sonarr.xml" "$url" "$tmp/radarr.xml")
script=ansible/roles/arr_stack/files/arr-bazarr.py
osuser="viewer-$(hex | cut -c1-6)"; ospass="pw-$(hex)"
account=$(printf '{"opensubtitles_username": "%s", "opensubtitles_password": "%s"}' "$osuser" "$ospass")

python3 "$script" --check "$policy" <<<"$account" >"$tmp/check.out" 2>&1
check "--check says what it would set" \
  "grep -q 'sonarr.apikey: would set' '$tmp/check.out' && grep -q 'profile English: would create' '$tmp/check.out' && grep -q 'sonarr: import .srt files: would switch on' '$tmp/check.out'"
check "--check writes nothing" "[ ! -e '$tmp/writes' ]"

python3 "$script" "$policy" <<<"$account" >"$tmp/run.out" 2>&1
check "the first run passes" "grep -q 'do: set' '$tmp/run.out'"
w=$tmp/writes
settings() { python3 -c "
import json
w=[json.loads(l) for l in open('$w')]
s=[x['body'] for x in w if x['path']=='/api/system/settings'][0]
$1"; }
check "connected to Sonarr and Radarr on their compose names, with their keys" \
  "settings 'assert s[\"settings-general-use_sonarr\"]==[\"true\"] and s[\"settings-sonarr-ip\"]==[\"sonarr\"] and s[\"settings-sonarr-apikey\"]==[\"$skey\"] and s[\"settings-radarr-apikey\"]==[\"$rkey\"]'"
check "English switched on, an English profile next to the existing one" \
  "settings 'p=json.loads(s[\"languages-profiles\"][0]); assert s[\"languages-enabled\"]==[\"en\"]; assert [x[\"name\"] for x in p]==[\"Kannada\",\"English\"]; e=p[1]; assert e[\"profileId\"]==2 and [i[\"language\"] for i in e[\"items\"]]==[\"en\"]'"
check "new series and movies get the English profile" \
  "settings 'assert s[\"settings-general-serie_default_enabled\"]==[\"true\"] and s[\"settings-general-serie_default_profile\"]==[\"2\"] and s[\"settings-general-movie_default_profile\"]==[\"2\"]'"
check "the account and OpenSubtitles.com are set, a provider added by hand is kept" \
  "settings 'assert s[\"settings-opensubtitlescom-username\"]==[\"$osuser\"] and s[\"settings-opensubtitlescom-password\"]==[\"$ospass\"] and sorted(s[\"settings-general-enabled_providers\"])==[\"opensubtitlescom\",\"podnapisi\"]'"
check "series and movies without a profile get English, one with a profile keeps it" "python3 -c '
import json
w=[json.loads(l) for l in open(\"$w\")]
s=[x[\"body\"] for x in w if x[\"path\"]==\"/api/series\"][0]; m=[x[\"body\"] for x in w if x[\"path\"]==\"/api/movies\"][0]
assert s==dict(seriesid=[\"5\"], profileid=[\"2\"]) and m==dict(radarrid=[\"9\"], profileid=[\"2\"]), (s, m)
'"
check "Sonarr and Radarr import .srt files" \
  "[ \"\$(grep -c 'config/mediamanagement/1' '$w')\" = 2 ] && grep -q '\"importExtraFiles\": true' '$w'"
check "no key and no part of the account is printed" \
  "! grep -qE '$bkey|$skey|$rkey|$ospass|$osuser' '$tmp/check.out' '$tmp/run.out'"

: >"$w"
python3 "$script" "$policy" <<<"$account" >"$tmp/again.out" 2>&1
check "a second run changes nothing" "[ ! -s '$w' ] && ! grep -qE 'do:|would' '$tmp/again.out'"

python3 "$script" "$policy" <<<'{}' >"$tmp/noacct.out" 2>&1
check "without an account it says so and does not clear the one that is set" \
  "grep -q 'no OpenSubtitles.com account' '$tmp/noacct.out' && [ ! -s '$w' ]"

[ "$fail" = 0 ] && echo "PASS: arr bazarr"
exit "$fail"
