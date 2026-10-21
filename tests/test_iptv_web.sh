#!/usr/bin/env bash
# The stream helper's web routes (ansible/roles/iptv/files/streams/server.py), run locally on
# a free port with a two-channel lineup and a fixture guide; no stream is started:
#   page      / and the /static/ assets answer 200 (the page with its CSP), gzip when asked
#   allowlist any other path is a 404: traversal (plain, encoded, doubled slashes), the
#             helper's own files, other names under /static/
#   guide     /guide.json is JSON with every lineup channel in order and the right now/next,
#             follows a guide replaced by rename, and still lists the channels without one
#   vendor    the vendored mpegts.js matches iptv_mpegts_sha256, and the web directory
#             holds exactly iptv_web_files (role defaults)
#   slots     with a fake streamlink (one chunk every 5 s) and one slot: a channel that
#             is not live is a 504, a second stream a 503, and a client that disconnects
#             frees its slot at once (not at the next chunk)
# shellcheck disable=SC2015  # `check && pass || bad`: pass only echoes
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

role=ansible/roles/iptv
web="$role/files/streams/web"
fail=0
pass() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fail=1; }

work=$(mktemp -d)
pid=
cleanup() { [ -n "$pid" ] && { kill "$pid"; wait "$pid"; } 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT

# --- vendor -------------------------------------------------------------------------------
want=$(sed -n 's/^iptv_mpegts_sha256: *//p' "$role/defaults/main.yml")
have=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$web/mpegts.js")
if [ -n "$want" ] && [ "$want" = "$have" ]; then pass "vendor: mpegts.js sha256"; else bad "vendor: mpegts.js sha256 $have, defaults say ${want:-nothing}"; fi
listed=$(sed -n 's/^iptv_web_files: *\[\(.*\)\]$/\1/p' "$role/defaults/main.yml" | tr -d ' ' | tr ',' '\n' | sort)
present=$(find "$web" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort)
if [ -n "$listed" ] && [ "$listed" = "$present" ]; then pass "vendor: web files = iptv_web_files"
else bad "vendor: web directory ($(tr '\n' ' ' <<<"$present")) differs from iptv_web_files ($(tr '\n' ' ' <<<"$listed"))"; fi

# --- server -------------------------------------------------------------------------------
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
guide="$work/guide/guide.xml"
mkdir -p "$work/guide"
# write_guide <title of the current publictv programme>: now/next around the current time.
write_guide() {
  python3 - "$guide" "$1" <<'EOF'
import datetime as dt, os, sys
path, title = sys.argv[1], sys.argv[2]
ist = dt.timezone(dt.timedelta(hours=5, minutes=30))
now = dt.datetime.now(ist).replace(microsecond=0)
f = lambda t: t.strftime("%Y%m%d%H%M%S %z")
progs = [("publictv", now - dt.timedelta(minutes=10), now + dt.timedelta(minutes=20), title),
         ("publictv", now + dt.timedelta(minutes=20), now + dt.timedelta(minutes=50), "Next & Later"),
         ("other", now - dt.timedelta(minutes=10), now + dt.timedelta(minutes=20), "Not in the lineup")]
xml = ['<?xml version="1.0" encoding="UTF-8"?>', "<tv>",
       '<channel id="publictv"><display-name>Public TV</display-name></channel>']
for cid, a, b, t in progs:
    t = t.replace("&", "&amp;")
    xml.append(f'<programme start="{f(a)}" stop="{f(b)}" channel="{cid}"><title lang="en">{t}</title></programme>')
xml.append("</tv>")
tmp = path + ".tmp"
open(tmp, "w").write("\n".join(xml) + "\n")
os.replace(tmp, path)  # as the grabber does: a new file, renamed over the old one
EOF
}
write_guide "Morning News"

# Fake streamlink: nothing for an "offline" source, else a TS-sized chunk now and every 5 s.
mkdir -p "$work/bin"
cat >"$work/bin/streamlink" <<'EOF'
#!/bin/sh
case "$*" in *offline*) exit 1 ;; esac
exec python3 -c 'import sys, time
while True:
    sys.stdout.buffer.write(b"G" + bytes(187)); sys.stdout.flush(); time.sleep(5)'
EOF
chmod +x "$work/bin/streamlink"

PATH="$work/bin:$PATH" IPTV_MAX_STREAMS=1 \
IPTV_CHANNELS='{"publictv": "https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxx/live", "tv9kannada": "https://www.youtube.com/channel/UCyyyyyyyyyyyyyyyyyyyyyy/live", "gone": "https://offline.example/live"}' \
IPTV_LINEUP='[{"id": "tv9kannada", "name": "TV9 Kannada", "number": 2}, {"id": "publictv", "name": "Public TV", "number": 1}]' \
IPTV_GUIDE="$guide" IPTV_WEB_DIR="$web" IPTV_PORT="$port" \
  python3 "$role/files/streams/server.py" 2>"$work/server.log" &
pid=$!
base="http://127.0.0.1:$port"
for _ in $(seq 50); do curl -fs "$base/health" >/dev/null 2>&1 && break; sleep 0.1; done
curl -fs "$base/health" >/dev/null || { cat "$work/server.log"; bad "server did not start"; exit 1; }

code() { curl --path-as-is -s -o /dev/null -w '%{http_code}' "$@"; }

# page
for p in / /static/app.css /static/app.js /static/mpegts.js /static/mpegts.LICENSE.txt /static/mpegts.js.LICENSE.txt; do
  c=$(code "$base$p"); [ "$c" = 200 ] && pass "page: $p 200" || bad "page: $p answered $c"
done
c=$(code -I "$base/"); [ "$c" = 200 ] && pass "page: HEAD / 200" || bad "page: HEAD / answered $c"
if curl -sI "$base/" | grep -qi "^content-security-policy: default-src 'none'"; then pass "page: CSP"; else bad "page: no CSP on /"; fi
if curl -s "$base/static/mpegts.js" | cmp -s - "$web/mpegts.js"; then pass "page: mpegts.js served as vendored"; else bad "page: mpegts.js body differs"; fi
if curl -s -H 'Accept-Encoding: gzip' "$base/static/mpegts.js" | gzip -dc | cmp -s - "$web/mpegts.js"; then pass "page: gzip"; else bad "page: gzip body differs"; fi
etag=$(curl -sI "$base/static/app.js" | sed -n 's/^[Ee][Tt][Aa][Gg]: *//p' | tr -d '\r')
c=$(code -H "If-None-Match: $etag" "$base/static/app.js"); [ "$c" = 304 ] && pass "page: ETag 304" || bad "page: If-None-Match answered $c"

# allowlist
for p in /index.html /static /static/ /static/server.py /static/../server.py /static/%2e%2e/server.py \
         /static/..%2fserver.py /static//app.js /static/app.js/ /static/./app.js /../server.py \
         /%2e%2e/%2e%2e/etc/passwd /..%2f..%2fetc%2fpasswd /etc/passwd /app/server.py /server.py \
         /web/app.js /static/APP.JS /guide.xml /guide/guide.xml /guide.json/ /favicon.ico /nochannel /publictv/../tv9kannada/x; do
  c=$(code "$base$p"); [ "$c" = 404 ] && pass "allowlist: $p 404" || bad "allowlist: $p answered $c"
  c=$(code -I "$base$p"); [ "$c" = 404 ] || bad "allowlist: HEAD $p answered $c"
done
c=$(code -I "$base/publictv"); [ "$c" = 200 ] && pass "allowlist: HEAD of a lineup channel 200" || bad "allowlist: HEAD /publictv answered $c"

# guide
check_guide() { # <expected publictv now title or "-" for none> <expected guide flag>
  curl -s "$base/guide.json" | python3 -c '
import json, sys
d = json.load(sys.stdin)
want_now, want_guide = sys.argv[1], sys.argv[2] == "true"
ids = [c["id"] for c in d["channels"]]
assert ids == ["publictv", "tv9kannada"], ids
assert d["guide"] is want_guide, d["guide"]
p = d["channels"][0]
if want_now == "-":
    assert p["now"] is None and p["next"] is None, p
else:
    assert p["now"]["title"] == want_now, p
    assert p["next"]["title"] == "Next & Later", p
    assert p["now"]["start"] <= d["time"] < p["now"]["stop"] == p["next"]["start"], p
assert d["channels"][1]["now"] is None and d["channels"][1]["name"] == "TV9 Kannada"
' "$1" "$2"
}
check_guide "Morning News" true && pass "guide: now/next" || bad "guide: now/next"
sleep 1
write_guide "Afternoon Bulletin"
check_guide "Afternoon Bulletin" true && pass "guide: follows a replaced guide" || bad "guide: replaced guide not picked up"
mv "$guide" "$guide.gone"
check_guide - false && pass "guide: no guide, channels still listed" || bad "guide: without a guide file"
printf 'not xml' >"$guide"
check_guide - false && pass "guide: unparseable guide, channels still listed" || bad "guide: unparseable guide"
kill -0 "$pid" 2>/dev/null && pass "server still running" || bad "server died"

# slots
c=$(code --max-time 10 "$base/gone"); [ "$c" = 504 ] && pass "slots: not live -> 504" || bad "slots: offline channel answered $c"
curl -s -o /dev/null --max-time 2 "$base/publictv" &
sleep 0.7
c=$(code --max-time 3 "$base/tv9kannada"); [ "$c" = 503 ] && pass "slots: second stream -> 503" || bad "slots: second stream answered $c"
wait $!
sleep 0.5 # well before the first stream's next chunk (5 s)
c=$(code --max-time 1 "$base/tv9kannada"); [ "$c" = 200 ] && pass "slots: a disconnect frees the slot at once" || bad "slots: after a disconnect answered $c"

if [ "$fail" != 0 ]; then echo "--- server log"; cat "$work/server.log"; echo "FAIL: IPTV web checks"; exit 1; fi
echo "PASS: IPTV web checks"
