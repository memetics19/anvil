#!/usr/bin/env bash
# Pulse (role pulse): the templates render, and pulse-update, run against a local git repo
# with fake docker, compose and curl:
#  - the first run takes the newest vX.Y.Z (by version, not by name), copies the data
#    before the switch, records the release and builds the docs from main;
#  - a second run with nothing new changes nothing;
#  - --check reports and changes nothing;
#  - a new release that does not answer is rolled back to the image that ran before, and
#    the data copy is put back (run for real against directories, with the data
#    directory standing in for the volume's mount point: it cannot be removed itself);
#  - the failed tag is skipped on later runs (no restart, no new data copy) until --retry
#    or a newer tag, and data copies beyond KEEP are dropped after a failure too;
#  - TRACK=<major> stays on that major, latest moves to a new one;
#  - TRACK pins a tag; a new main commit rebuilds the docs and drops the old build;
#  - with VERIFY=true a signed image runs by its digest, an unsigned one is not deployed;
#  - a rollback whose data restore fails writes state/hold: later runs do nothing (--check
#    reports it) and the held data copy is never pruned;
#  - a first install that is not healthy in time is left running, not marked failed, and
#    recorded by a later run once it answers;
#  - the digest checked and run is the RepoDigests entry of IMAGE, never another name's,
#    and a pull with none fails;
#  - the role writes the setup token to pulse_vault_mount, by patch when the path has keys
#    (vault-kv-digests.sh reads that mount), and every role passes its mount to it.
# Needs ansible-playbook, git, jq and python3 with PyYAML.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
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
    pulse_setup_token: test-token
    caddy_image_resolved: anvil/caddy:test
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
  "python3 -c 'import yaml,sys; d=yaml.safe_load(open(\"$tmp/compose.yaml\")); s=d[\"services\"]; assert d[\"name\"]==\"pulse\"; assert s[\"pulse\"][\"image\"].startswith(\"\${PULSE_IMAGE\"); assert \"pulse_data:/data\" in s[\"pulse\"][\"volumes\"]; assert \"pulse_data\" in d[\"volumes\"]; assert s[\"pulse\"][\"environment\"][\"PULSE_DB\"]==\"\${PULSE_DB:-}\"'"
check "compose: Caddy is the patched build, not upstream's binary" "grep -q 'image: anvil/caddy:test' '$tmp/compose.yaml'"
check "compose: no secret value in the compose file" "! grep -q test-token '$tmp/compose.yaml'"
check ".env: holds the setup token" "grep -qx 'PULSE_SETUP_TOKEN=test-token' '$tmp/env'"
check "compose: passes the setup token from .env" "grep -qx '      PULSE_SETUP_TOKEN: \${PULSE_SETUP_TOKEN:-}' '$tmp/compose.yaml'"
check "Caddyfile: docs.* gets the docs site, the rest the status page" \
  "grep -q 'header_regexp Host ^docs' '$tmp/Caddyfile' && grep -q 'root \* /srv/docs/current' '$tmp/Caddyfile' && grep -q 'reverse_proxy pulse:8080' '$tmp/Caddyfile'"
check "update.conf: follows one major version by default" "grep -qx 'TRACK=3' '$tmp/update.conf'"
check "update.conf: checks signatures by default, cosign pinned by digest" \
  "grep -qx 'VERIFY=true' '$tmp/update.conf' && grep -q '^COSIGN_IMAGE=.*@sha256:' '$tmp/update.conf' && grep -q '^SIGNER=.*memetics19/pulse/' '$tmp/update.conf'"

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
  # The digests a tag points at, one per line: IMAGE@sha256:fake-<version>, or one per name
  # in FAKE_REPO_DIGESTS (the same image known under other names too). `index .RepoDigests
  # 0` gets the first.
  "image inspect")
    d=()
    for r in ${FAKE_REPO_DIGESTS:-${5%:*}}; do d+=("$r@sha256:fake-${5##*:}"); done
    case $4 in *"index .RepoDigests 0"*) echo "${d[0]}" ;; *) printf '%s\n' "${d[@]}" ;; esac
    exit 0 ;;
esac
# cosign verify: every image is signed except FAKE_UNSIGNED.
if [ "$1" = run ] && [[ " $* " == *" verify "* ]]; then
  [[ -n "${FAKE_UNSIGNED:-}" && " $* " == *" $FAKE_UNSIGNED "* ]] && exit 1
  exit 0
fi
if [ "$1" = run ]; then
  for a in "$@"; do
    case $a in
      /out/*) mkdir -p "$FAKE_DIR/docs/${a#/out/}" && touch "$FAKE_DIR/docs/${a#/out/}/index.html" ;;
    esac
  done
  # The data copy runs for real: '/data' is FAKE_VOLUME (a directory that cannot be
  # removed, like a mount point) and '/backup' is the backups directory.
  last=${*: -1}
  case $last in
    *"cp -a '"*)
      cmd=${last//\'\/data/\'$FAKE_VOLUME}
      cmd=${cmd//\'\/backup/\'$FAKE_DIR\/backups}
      # FAKE_RESTORE_FAILS: copying a backup back empties the volume, then the copy fails.
      if [ -n "${FAKE_RESTORE_FAILS:-}" ] && [[ $last == *"cp -a '/backup/"* ]]; then
        sh -c "${cmd%% && cp -a*}"
        exit 1
      fi
      sh -c "$cmd" || exit 1
      ;;
  esac
fi
exit 0
EOF
cat >"$bin/compose" <<'EOF'
#!/bin/bash
# Like pulse-compose: it reads release.env, and fails without it.
[ -f "$FAKE_DIR/release.env" ] || { echo "couldn't find env file: $FAKE_DIR/release.env" >&2; exit 1; }
# A bad release starts and damages the data before it fails its health check.
if [ "$1" = up ] && [ -n "${FAKE_BAD_IMAGE:-}" ] && grep -q "=$FAKE_BAD_IMAGE\$" "$FAKE_DIR/release.env"; then
  echo "damaged" >"$FAKE_VOLUME/pulse.db"
  touch "$FAKE_VOLUME/written-by-bad-release"
fi
echo "compose $*" >>"$FAKE_LOG"
# FAKE_NO_CONTAINER: the project has no container yet (a first install).
[ "$1 $2" = "ps -aq" ] && [ -z "${FAKE_NO_CONTAINER:-}" ] && echo cid1
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
# The Pulse data volume: its parent is read-only, so the directory itself cannot be removed,
# like the mount point inside the real copy container. Only its contents can change.
vol="$tmp/mnt/volume"
mkdir -p "$vol"
echo "the real data" >"$vol/pulse.db"
chmod 555 "$tmp/mnt"
mkdir -p "$dir"
conf="$tmp/test.conf"
sed -e "s#^REPO=.*#REPO=file://$up#" -e "s#^DIR=.*#DIR=$dir#" -e "s#^COMPOSE=.*#COMPOSE=$bin/compose#" \
  -e "s#^HEALTH_TIMEOUT=.*#HEALTH_TIMEOUT=6#" -e "s#^KEEP=.*#KEEP=1#" -e "s#^TRACK=.*#TRACK=latest#" -e "s#^VERIFY=.*#VERIFY=false#" \
  "$tmp/update.conf" >"$conf"
cp "$conf" "$tmp/base.conf"
fresh() { # fresh <name>: a new DIR and data volume, with the settings above
  dir="$tmp/$1" vol="$tmp/mnt-$1/volume" conf="$tmp/$1.conf"
  mkdir -p "$dir" "$vol"
  echo "the real data" >"$vol/pulse.db"
  chmod 555 "$tmp/mnt-$1"
  sed "s#^DIR=.*#DIR=$dir#" "$tmp/base.conf" >"$conf"
}
upd() { PATH="$bin:$PATH" FAKE_LOG="$log" FAKE_DIR="$dir" FAKE_VOLUME="$vol" PULSE_UPDATE_CONF="$conf" bash "$tmp/pulse-update.sh" "$@" >"$tmp/out" 2>&1; }
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
check "mkdocs runs from the repository root (snippets paths)" "grep -q 'docker run --rm -w /workspace' '$log'"
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
check "the data copy is put back into the volume" "[ \"\$(cat '$vol/pulse.db')\" = 'the real data' ] && [ ! -e '$vol/written-by-bad-release' ]"
check "the volume's mount point itself is never removed" "[ -d '$vol' ]"
check "the recorded release stays v1.10.0" "[ \"\$(cat '$dir/state/version')\" = v1.10.0 ]"
check "the failed tag is recorded" "[ \"\$(cat '$dir/state/failed')\" = v1.11.0 ]"
check "data copies beyond KEEP are dropped after a failed deploy too" "[ \$(ls '$dir/backups' | wc -l) -le 1 ]"

# 4b. the failed tag is not tried again on the next tick
: >"$log"
if FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.11.0 FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.10.0 upd &&
  grep -q "skipping v1.11.0" "$tmp/out" && ! grep -q -E 'compose (stop|up)|cp -a' "$log"; then
  ok "a failed tag is skipped: no restart, no data copy"; else bad_ "failed tag skipped"; cat "$tmp/out" "$log"; fi
if upd --check && grep -q "v1.11.0 failed before" "$tmp/out"; then ok "--check says the tag is skipped"; else bad_ "--check skip"; cat "$tmp/out"; fi
: >"$log"
if FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.11.0 FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.10.0 upd --retry; then
  bad_ "--retry deploys the failed tag again"; else
  if grep -q 'compose up' "$log"; then ok "--retry deploys the failed tag again"; else bad_ "--retry"; cat "$tmp/out"; fi; fi

# 4c. a newer tag is tried, and a good one clears the failure
git -C "$up" tag v1.12.0
if FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.10.0 upd && grep -q "deployed v1.12.0" "$tmp/out" && [ ! -e "$dir/state/failed" ]; then
  ok "a newer tag is deployed and clears the failure"; else bad_ "newer tag after a failure"; cat "$tmp/out"; fi

# 4d. a major version pin
git -C "$up" tag v2.1.0
sed -i.bak 's#^TRACK=.*#TRACK=1#' "$conf"
if upd --check && grep -q "app: v1.12.0, up to date" "$tmp/out"; then ok "TRACK=1 stays on 1.x when 2.x is out"; else bad_ "major pin"; cat "$tmp/out"; fi
sed -i.bak 's#^TRACK=.*#TRACK=latest#' "$conf"
if upd --check && grep -q "would deploy v2.1.0" "$tmp/out"; then ok "TRACK=latest moves to the new major"; else bad_ "latest across majors"; cat "$tmp/out"; fi
sed -i.bak 's#^TRACK=.*#TRACK=3x#' "$conf"
if upd --check; then bad_ "a bad TRACK is refused"; else ok "a bad TRACK is refused"; fi

# 5. a pin, and a new docs commit
old_docs=$(main_sha)
git -C "$up" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m "docs 2"
sed -i.bak 's#^TRACK=.*#TRACK=v1.2.0#' "$conf"
if FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.10.0 upd && grep -q "deployed v1.2.0" "$tmp/out"; then ok "TRACK pins a tag"; else bad_ "pin"; cat "$tmp/out"; fi
check "a new main commit rebuilds the docs" "[ \"\$(readlink '$dir/docs/current')\" = \"\$(git -C '$up' rev-parse main)\" ]"
check "the build before the previous one is dropped, the previous kept" "[ -d '$dir/docs/$old_docs' ]"
check "backups beyond KEEP are dropped" "[ \$(ls '$dir/backups' | wc -l) -le 1 ]"

# 6. signatures
git -C "$up" tag v1.13.0
git -C "$up" tag v1.14.0
sed -i.bak -e 's#^VERIFY=.*#VERIFY=true#' -e 's#^TRACK=.*#TRACK=v1.13.0#' "$conf"
: >"$log"
if FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.2.0 upd && grep -q "deployed v1.13.0" "$tmp/out"; then ok "a signed release is deployed"; else bad_ "signed release"; cat "$tmp/out"; fi
check "the signature is checked against the release workflow and GitHub's issuer" \
  "grep -q 'verify ghcr.io/memetics19/pulse@sha256:fake-1.13.0 --certificate-identity-regexp .*memetics19/pulse/.*--certificate-oidc-issuer https://token.actions.githubusercontent.com' '$log'"
check "Pulse runs the digest that was checked" "grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse@sha256:fake-1.13.0' '$dir/release.env'"
sed -i.bak 's#^TRACK=.*#TRACK=v1.14.0#' "$conf"
: >"$log"
if FAKE_UNSIGNED=ghcr.io/memetics19/pulse@sha256:fake-1.14.0 upd; then bad_ "an unsigned release fails the run"; else ok "an unsigned release fails the run"; fi
check "an unsigned release is never started, and Pulse is not stopped" \
  "grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse@sha256:fake-1.13.0' '$dir/release.env' && ! grep -q -E 'compose (stop|up)' '$log' && grep -q 'no valid signature' '$tmp/out'"

# 7. a rollback whose data restore fails: on hold until the data is restored by hand
fresh hold
sed -i.bak 's#^TRACK=.*#TRACK=v1.13.0#' "$conf"
FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.12.0 upd || { bad_ "hold: the first deploy"; cat "$tmp/out"; }
mkdir "$dir/backups/99991231-235959-newer" # newer than the copy the failed deploy takes
sed -i.bak 's#^TRACK=.*#TRACK=v1.14.0#' "$conf"
: >"$log"
if FAKE_RESTORE_FAILS=1 FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.14.0 FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.13.0 upd; then
  bad_ "a failed restore fails the run"; else ok "a failed restore fails the run"; fi
held=$(cat "$dir/state/hold" 2>/dev/null)
check "a failed restore writes state/hold, naming the data copy" \
  "[ -n '$held' ] && grep -q 'backups/$held' '$tmp/out' && [ \"\$(cat '$dir/backups/$held/pulse.db')\" = 'the real data' ]"
check "the held data copy is never pruned (KEEP=1, a newer copy exists)" "[ -n '$held' ] && [ -d '$dir/backups/$held' ]"
check "Pulse stays stopped, release.env names the image to start after the restore" \
  "[ \"\$(grep -E '^compose (stop|up)' '$log' | tail -n 1)\" = 'compose stop pulse' ] && grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse:1.13.0' '$dir/release.env'"
git -C "$up" tag v1.15.0
sed -i.bak 's#^TRACK=.*#TRACK=v1.15.0#' "$conf"
held_runs=ok
for a in "" --retry; do
  : >"$log"
  if FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.14.0 upd $a || ! grep -q 'state/hold' "$tmp/out" || [ -s "$log" ]; then
    held_runs=bad; cat "$tmp/out" "$log"; fi
done
if [ "$held_runs" = ok ]; then ok "on hold, a run (also --retry) fails and touches nothing, even for a newer tag"; else bad_ "runs on hold"; fi
: >"$log"
if upd --check && grep -q 'on hold' "$tmp/out" && grep -q "backups/$held" "$tmp/out" && [ ! -s "$log" ]; then
  ok "--check reports the hold"; else bad_ "--check on hold"; cat "$tmp/out"; fi
rm -f "$dir/state/hold"
if FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.13.0 upd && grep -q "deployed v1.15.0" "$tmp/out"; then
  ok "with state/hold removed, runs go on"; else bad_ "runs after the hold"; cat "$tmp/out"; fi

# 8. a first install that is not healthy in time (nothing to roll back to)
fresh first
sed -i.bak 's#^TRACK=.*#TRACK=v1.13.0#' "$conf"
: >"$log"
if FAKE_NO_CONTAINER=1 FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.13.0 upd; then
  bad_ "a slow first install fails the run"; else ok "a slow first install fails the run"; fi
check "it is not marked failed, and it is left running" \
  "[ ! -e '$dir/state/failed' ] && ! grep -q 'compose stop' '$log' && grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse:1.13.0' '$dir/release.env'"
: >"$log"
if FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.13.0 upd && ! grep -q -E 'compose (stop|up)|cp -a|pull' "$log" && [ ! -e "$dir/state/version" ]; then
  ok "while it does not answer, later runs leave it alone"; else bad_ "slow first install, next run"; cat "$tmp/out" "$log"; fi
if FAKE_BAD_IMAGE=ghcr.io/memetics19/pulse:1.13.0 upd --check && grep -q 'v1.13.0 is not healthy yet' "$tmp/out" && ! grep -q 'failed before' "$tmp/out"; then
  ok "--check says it waits for v1.13.0"; else bad_ "--check on a slow first install"; cat "$tmp/out"; fi
: >"$log"
if upd && grep -q 'v1.13.0 is healthy now' "$tmp/out" && [ "$(cat "$dir/state/version" 2>/dev/null)" = v1.13.0 ] &&
  [ ! -e "$dir/state/failed" ] && ! grep -q -E 'compose (stop|up)|cp -a|pull' "$log"; then
  ok "once it answers, the next run records it without a redeploy"; else bad_ "slow first install recorded"; cat "$tmp/out" "$log"; fi

# 9. the digest of IMAGE, when the image is also known under another name
fresh digest
sed -i.bak -e 's#^VERIFY=.*#VERIFY=true#' -e 's#^TRACK=.*#TRACK=v1.13.0#' "$conf"
: >"$log"
if FAKE_REPO_DIGESTS="registry.example/ghcr.io/memetics19/pulse ghcr.io/memetics19/pulse" FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.12.0 upd &&
  grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse@sha256:fake-1.13.0' "$dir/release.env" &&
  grep -q 'verify ghcr.io/memetics19/pulse@sha256:fake-1.13.0 ' "$log" && ! grep -q 'verify registry' "$log"; then
  ok "the RepoDigests entry of IMAGE is checked and run, not the first one"; else bad_ "digest of IMAGE"; cat "$tmp/out"; fi
sed -i.bak 's#^TRACK=.*#TRACK=v1.14.0#' "$conf"
: >"$log"
if FAKE_REPO_DIGESTS="registry.example/ghcr.io/memetics19/pulse" FAKE_PREV_IMAGE=ghcr.io/memetics19/pulse:1.13.0 upd; then
  bad_ "a pull with no digest of IMAGE fails the run"; else ok "a pull with no digest of IMAGE fails the run"; fi
check "it is never started, and Pulse is not stopped" \
  "grep -qx 'PULSE_IMAGE=ghcr.io/memetics19/pulse@sha256:fake-1.13.0' '$dir/release.env' && ! grep -q -E 'compose (stop|up)| verify ' '$log' && grep -q 'no digest' '$tmp/out'"

# 10. the setup token goes to pulse_vault_mount: the role's Vault tasks run against a fake
# vault, with pulse_vault_mount=secrets
vbin="$tmp/vbin"
mkdir -p "$vbin"
cat >"$vbin/vault" <<'EOF'
#!/bin/bash
# One KV v2 path on mount FAKE_VAULT_MOUNT, its keys in FAKE_VAULT_DATA ("key=value" lines).
echo "vault $*" >>"$FAKE_VAULT_LOG"
mount=
for a in "$@"; do case $a in -mount=*) mount=${a#-mount=} ;; esac; done
has_keys() { [ "$mount" = "$FAKE_VAULT_MOUNT" ] && [ -s "$FAKE_VAULT_DATA" ]; }
k=${*: -1} k=${k%=-}
case "$1 $2" in
  "kv get")
    has_keys || { echo "No value found at $mount/data/${*: -1}" >&2; exit 2; }
    python3 -c 'import json,sys; print(json.dumps({"data": {"data": dict(l.rstrip("\n").split("=", 1) for l in open(sys.argv[1]))}}))' "$FAKE_VAULT_DATA" ;;
  "kv put") # replaces every key, unless -cas=0 refuses a path that exists
    if [[ " $* " == *" -cas=0 "* ]] && has_keys; then echo "check-and-set parameter did not match the current version" >&2; exit 2; fi
    printf '%s=%s\n' "$k" "$(cat)" >"$FAKE_VAULT_DATA" ;;
  "kv patch") printf '%s=%s\n' "$k" "$(cat)" >>"$FAKE_VAULT_DATA" ;;
esac
EOF
chmod +x "$vbin/vault"
python3 - "$PWD/ansible/roles/pulse/tasks/main.yml" "$tmp/vault_tasks.yml" <<'PY'
import sys, yaml
tasks = yaml.safe_load(open(sys.argv[1]))
end = [t.get("name") for t in tasks].index("Generate the setup token into Vault")
yaml.safe_dump(tasks[:end + 1], open(sys.argv[2], "w"), sort_keys=False)
PY
cat >"$tmp/vault_play.yml" <<PLAY
- name: Pulse setup token
  hosts: localhost
  gather_facts: false
  vars:
    pulse_repo_scripts: $PWD/scripts
    pulse_vault_mount: secrets
    pulse_vault_path: homelab/netbird/pulse
  tasks:
    - ansible.builtin.include_tasks: $tmp/vault_tasks.yml
PLAY
vault_env() { env PATH="$vbin:$PATH" FAKE_VAULT_LOG="$tmp/vault.log" FAKE_VAULT_DATA="$tmp/vault.data" FAKE_VAULT_MOUNT=secrets "$@"; }
vrun() { : >"$tmp/vault.log"; vault_env ansible-playbook -i localhost, -c local "$tmp/vault_play.yml" >"$tmp/vault.out" 2>&1; }
printf 'other=keep\n' >"$tmp/vault.data"
if vrun && grep -q 'kv patch -mount=secrets homelab/netbird/pulse setup_token=-' "$tmp/vault.log" && ! grep -q 'kv put' "$tmp/vault.log" &&
  grep -qx 'other=keep' "$tmp/vault.data" && grep -q '^setup_token=.\{32\}' "$tmp/vault.data"; then
  ok "a path on pulse_vault_mount that has keys gets the token by patch, its keys kept"; else bad_ "setup token on another mount"; cat "$tmp/vault.out" "$tmp/vault.log"; fi
if vrun && ! grep -q -E 'kv (put|patch)' "$tmp/vault.log"; then
  ok "a token already in Vault is not written again"; else bad_ "setup token written again"; cat "$tmp/vault.out" "$tmp/vault.log"; fi
: >"$tmp/vault.data"
if vrun && grep -q 'kv put -cas=0 -mount=secrets homelab/netbird/pulse setup_token=-' "$tmp/vault.log" && grep -q '^setup_token=' "$tmp/vault.data"; then
  ok "an empty path gets the token by put, which Vault refuses once the path exists (-cas=0)"; else bad_ "setup token on an empty path"; cat "$tmp/vault.out" "$tmp/vault.log"; fi
: >"$tmp/vault.log"
vault_env scripts/vault-kv-digests.sh homelab/x >/dev/null 2>&1
check "vault-kv-digests.sh reads the kv mount when given none" "grep -q -- '-mount=kv homelab/x' '$tmp/vault.log'"
check "every role passes its mount to vault-kv-digests.sh" \
  "grep -rq 'vault-kv-digests.sh\"' ansible && ! grep -rE 'vault-kv-digests\.sh\", \"[^\"]*\"\]' ansible"

[ "$fail" = 0 ] && echo "PASS: pulse" || echo "FAIL: pulse"
exit "$fail"
