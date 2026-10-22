#!/usr/bin/env bash
# Pulse (role pulse): the templates render, and pulse-update, run against a local git repo
# with fake docker, compose and curl:
#  - the first run takes the newest vX.Y.Z (by version, not by name), copies the data
#    before the switch, records the release and builds the docs from main;
#  - a second run with nothing new changes nothing;
#  - --check reports and changes nothing;
#  - a new release that does not answer is rolled back to the image that ran before, and
#    the data copy is put back;
#  - TRACK pins a tag; a new main commit rebuilds the docs and drops the old build.
# Needs ansible-playbook, git and python3 with PyYAML.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# --- render the role's templates ---------------------------------------------------------------
cat >"$tmp/play.yml" <<PLAY
- name: Pulse templates
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: netbird
    site: {hosts: {netbird: {ip: 192.0.2.5}}}
    pulse_admin_token: test-token
  vars_files:
    - $PWD/ansible/roles/pulse/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/pulse/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0755"
      loop: [pulse-update.sh, compose.yaml, Caddyfile, update.conf, env, pulse-compose]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
check "compose: pulse image from release.env, data volume kept" \
  "python3 -c 'import yaml,sys; d=yaml.safe_load(open(\"$tmp/compose.yaml\")); s=d[\"services\"]; assert d[\"name\"]==\"pulse\"; assert s[\"pulse\"][\"image\"].startswith(\"\${PULSE_IMAGE\"); assert \"pulse_data:/data\" in s[\"pulse\"][\"volumes\"]; assert \"pulse_data\" in d[\"volumes\"]; assert s[\"pulse\"][\"environment\"][\"SQLITE_PATH\"]==\"\${SQLITE_PATH:-}\"'"
check "compose: no secret value in the compose file" "! grep -q test-token '$tmp/compose.yaml'"
check ".env: holds the admin token" "grep -qx 'PULSE_ADMIN_TOKEN=test-token' '$tmp/env'"
check "Caddyfile: docs.* gets the docs site, the rest the status page" \
  "grep -q 'header_regexp Host ^docs' '$tmp/Caddyfile' && grep -q 'root \* /srv/docs/current' '$tmp/Caddyfile' && grep -q 'reverse_proxy pulse:8080' '$tmp/Caddyfile'"
check "update.conf: follows the newest release by default" "grep -qx 'TRACK=latest' '$tmp/update.conf'"

# --- a fake upstream repo ------------------------------------------------------------------------
up="$tmp/upstream"
git init -q -b main "$up"
git -C "$up" config commit.gpgsign false
git -C "$up" config tag.gpgsign false
git -C "$up" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
printf 'site_name: t\n' >"$up/mkdocs.yml"
git -C "$up" add mkdocs.yml
git -C "$up" -c user.name=t -c user.email=t@example.com commit -q -m docs
for t in v1.0.0 v1.2.0 v1.10.0 v2.0.0-rc.1 latest-build; do git -C "$up" tag "$t"; done

# --- fakes: docker, compose, curl (and GNU tools on macOS) ----------------------------------------
bin="$tmp/bin"
mkdir -p "$bin"
log="$tmp/calls"
cat >"$bin/docker" <<'EOF'
#!/bin/bash
echo "docker $*" >>"$FAKE_LOG"
case "$1 $2" in
  "volume inspect") exit 0 ;;
  "inspect --format") echo "${FAKE_PREV_IMAGE:-pulse:latest}" ;;
  "image ls") exit 0 ;;
  "pull -q") exit 0 ;;
esac
if [ "$1" = run ]; then
  for a in "$@"; do
    case $a in
      /out/*) mkdir -p "$FAKE_DIR/docs/${a#/out/}" && touch "$FAKE_DIR/docs/${a#/out/}/index.html" ;;
      # the data copy: a copy into /backup/<name> leaves that directory behind
      *"mkdir -p '/backup/"*) d=${a#*mkdir -p \'/backup/}; mkdir -p "$FAKE_DIR/backups/${d%%\'*}" ;;
    esac
  done
fi
exit 0
EOF
cat >"$bin/compose" <<'EOF'
#!/bin/bash
echo "compose $*" >>"$FAKE_LOG"
[ "$1 $2" = "ps -aq" ] && echo cid1
exit 0
EOF
# Healthy unless release.env names FAKE_BAD_IMAGE.
cat >"$bin/curl" <<'EOF'
#!/bin/bash
[ -n "${FAKE_BAD_IMAGE:-}" ] && grep -q "=$FAKE_BAD_IMAGE\$" "$FAKE_DIR/release.env" && exit 7
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$bin/sleep"
command -v flock >/dev/null || printf '#!/bin/sh\nexit 0\n' >"$bin/flock"
# macOS mv has no -T (the VM's GNU mv does): rename over the link the same way.
if ! mv --version >/dev/null 2>&1; then
  cat >"$bin/mv" <<'SH'
#!/bin/sh
[ "$1" = -T ] && exec python3 -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])' "$2" "$3"
exec /bin/mv "$@"
SH
fi
chmod +x "$bin"/*

dir="$tmp/opt"
mkdir -p "$dir"
conf="$tmp/test.conf"
sed -e "s#^REPO=.*#REPO=file://$up#" -e "s#^DIR=.*#DIR=$dir#" -e "s#^COMPOSE=.*#COMPOSE=$bin/compose#" \
  -e "s#^HEALTH_TIMEOUT=.*#HEALTH_TIMEOUT=6#" -e "s#^KEEP=.*#KEEP=2#" "$tmp/update.conf" >"$conf"
upd() { PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_DIR="$dir" PULSE_UPDATE_CONF="$conf" bash "$tmp/pulse-update.sh" "$@" >"$tmp/out" 2>&1; }
main_sha() { git -C "$up" rev-parse main; }

# 1. first run over a container nothing recorded
: >"$log"
if upd && grep -q "deployed v1.10.0 (was pulse:latest)" "$tmp/out"; then ok "first run deploys the newest vX.Y.Z (v1.10.0, not v1.2.0 or an rc)"; else bad_ "first run"; cat "$tmp/out"; fi
check "release.env names the ghcr image of the tag" "grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse:1.10.0' '$dir/release.env'"
check "the release is recorded" "[ \"\$(cat '$dir/state/version')\" = v1.10.0 ]"
stopped_first() { # the data copy (docker run ... cp) sits between compose stop and compose up
  local stop copy upl
  stop=$(grep -n 'compose stop pulse' "$log" | head -1 | cut -d: -f1)
  copy=$(grep -n "cp -a '/data/.'" "$log" | head -1 | cut -d: -f1)
  upl=$(grep -n 'compose up' "$log" | head -1 | cut -d: -f1)
  [ -n "$stop" ] && [ -n "$copy" ] && [ -n "$upl" ] && [ "$stop" -lt "$copy" ] && [ "$copy" -lt "$upl" ]
}
check "the data was copied while Pulse was stopped, before the switch" "ls '$dir/backups' | grep -q -- '-first\$' && stopped_first"
check "the docs were built from main" "[ \"\$(cat '$dir/state/docs')\" = \"\$(git -C '$up' rev-parse main)\" ] && [ -f '$dir/docs/current/index.html' ]"

# 2. nothing new
: >"$log"
if upd && [ ! -s "$log" ]; then ok "a second run with nothing new changes nothing"; else bad_ "second run"; cat "$tmp/out" "$log"; fi

# 3. --check
git -C "$up" tag v1.11.0
: >"$log"
if upd --check && grep -q "would deploy v1.11.0" "$tmp/out" && [ ! -s "$log" ] && [ "$(cat "$dir/state/version")" = v1.10.0 ]; then
  ok "--check reports and changes nothing"; else bad_ "--check"; cat "$tmp/out"; fi

# 4. a release that does not answer
: >"$log"
if FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.11.0 FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.10.0 upd; then bad_ "an unhealthy release fails the run"; else ok "an unhealthy release fails the run"; fi
check "it is rolled back to the image that ran before" "grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse:1.10.0' '$dir/release.env' && grep -q 'rolled back to ghcr.io/memetics19/pulse:1.10.0' '$tmp/out'"
check "the data copy is put back" "grep -q \"sh -c rm -rf '/data'\" '$log'"
check "the recorded release stays v1.10.0" "[ \"\$(cat '$dir/state/version')\" = v1.10.0 ]"

# 5. a pin, and a new docs commit
old_docs=$(main_sha)
git -C "$up" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "docs 2"
sed -i.bak 's#^TRACK=.*#TRACK=v1.2.0#' "$conf"
if FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.10.0 upd && grep -q "deployed v1.2.0" "$tmp/out"; then ok "TRACK pins a tag"; else bad_ "pin"; cat "$tmp/out"; fi
check "a new main commit rebuilds the docs" "[ \"\$(readlink '$dir/docs/current')\" = \"\$(git -C '$up' rev-parse main)\" ]"
check "the build before the previous one is dropped, the previous kept" "[ -d '$dir/docs/$old_docs' ]"
check "backups beyond KEEP are dropped" "[ \$(ls '$dir/backups' | wc -l) -le 2 ]"

[ "$fail" = 0 ] && echo "PASS: pulse" || echo "FAIL: pulse"
exit "$fail"
