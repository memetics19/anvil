#!/usr/bin/env bash
# The IPTV lineup (iptv/channels.yml) holds official free sources only. Checks the real
# file (must pass) and fixtures that each add one violation (each must fail):
#   source    every source is a YouTube channel's /live URL (no restreams, no other hosts)
#   paid      no subscription channel (Zee, Colors, Udaya, Star, Sun, Sony) in the lineup
#   unique    ids and numbers are unique
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# check <file>: prints "FAIL <rule>: ..." lines; returns 1 if any.
check() {
  python3 - "$1" <<'EOF'
import json, re, subprocess, sys
path = sys.argv[1]
try:
    import yaml
    doc = yaml.safe_load(open(path))
except ImportError:  # no PyYAML: the system Ruby's Psych
    doc = json.loads(subprocess.check_output(
        ["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.safe_load(File.read(ARGV[0])))", path]))
channels = (doc or {}).get("channels") or []
fail = []
if not channels:
    fail.append("source: no channels")
# fullmatch: no trailing newline or anything else after /live.
src = re.compile(r"https://www\.youtube\.com/channel/UC[A-Za-z0-9_-]{22}/live")
paid = re.compile(r"zee|colou?rs|udaya|star|\bsun\b|sony", re.I)
for c in channels:
    if not src.fullmatch(str(c.get("source", ""))):
        fail.append(f"source: {c.get('id')}: {c.get('source')}")
    if paid.search(f"{c.get('id', '')} {c.get('name', '')}"):
        fail.append(f"paid: {c.get('id')}: {c.get('name')}")
for key in ("id", "number"):
    values = [c.get(key) for c in channels]
    if len(values) != len(set(map(str, values))):
        fail.append(f"unique: duplicate {key}")
for f in fail:
    print("FAIL " + f)
sys.exit(1 if fail else 0)
EOF
}

fail=0
if out=$(check iptv/channels.yml); then echo "PASS real lineup"; else echo "$out"; echo "FAIL real lineup"; fail=1; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# case_ <name> <expected rule> <channel entry appended to the lineup>
case_() {
  local name=$1 rule=$2 entry=$3 f="$work/$1.yml"
  cp iptv/channels.yml "$f"
  printf '%s\n' "$entry" >>"$f"
  if out=$(check "$f"); then
    echo "FAIL case $name: expected rule $rule, the lineup passed"; fail=1
  elif grep -q "^FAIL $rule:" <<<"$out"; then
    echo "PASS case $name ($rule)"
  else
    echo "FAIL case $name: expected rule $rule, got: ${out:-nothing}"; fail=1
  fi
}
yt="https://www.youtube.com/channel/UCxxxxxxxxxxxxxxxxxxxxxx/live"
case_ restream source "  - {id: zz, name: Restream, number: 90, source: 'https://example.com/live/index.m3u8'}"
case_ trailing-newline source "  - {id: zz, name: Newline, number: 90, source: \"$yt\\n\"}"
case_ video-id source "  - {id: zz, name: Video, number: 90, source: 'https://www.youtube.com/watch?v=abcdefghijk'}"
case_ paid paid "  - {id: zeekannada, name: Zee Kannada, number: 90, source: '$yt'}"
case_ paid-colors paid "  - {id: colorskannada, name: Colors Kannada, number: 90, source: '$yt'}"
case_ duplicate unique "  - {id: publictv, name: Again, number: 90, source: '$yt'}"

if [ "$fail" != 0 ]; then echo "FAIL: IPTV lineup checks"; exit 1; fi
echo "PASS: IPTV lineup checks"
