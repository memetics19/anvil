#!/usr/bin/env bash
# Copy the secrets the live VMs use into Vault (KV v2, mount kv, kv/homelab/<host>/<app>).
# docs/secrets.md lists every path and key. Each value is read on the VM (as root, via
# sudo fed from ANSIBLE_BECOME_PASSWORD, see remote_wrap) and travels ssh stdout -> `vault kv put|patch
# <path> <key>=-` stdin: never argv, never disk, never printed. Hosts resolve from the
# site dict (kv/homelab/site) at run time.
# Per key: SHA-256 of the VM value vs the Vault value. Equal -> unchanged; missing ->
# written; different -> refused unless --force. Every key is read back and compared.
# Prints only path, key and unchanged|written|match|MISMATCH|missing|differs.
#   usage: scripts/import-secrets.sh [--force | --verify]
#     --verify  compare only, write nothing (exit 1 on any difference)
set -euo pipefail
{ set +x; } 2>/dev/null

die() { echo "import-secrets: $*" >&2; exit 1; }

[ $# -le 1 ] || die "usage: $0 [--force | --verify]"
mode=import
case ${1:-} in
  --force) mode=force ;;
  --verify) mode=verify ;;
  "") ;;
  *) die "usage: $0 [--force | --verify]" ;;
esac

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null  # env.sh ends in a top-level return, which confuses -x
source "$root/scripts/env.sh"

[ -n "${VAULT_TOKEN:-}" ] || die "VAULT_TOKEN not set (Keychain vault-init-json)"
[ -n "${ANSIBLE_BECOME_PASSWORD:-}" ] || die "ANSIBLE_BECOME_PASSWORD not set (Keychain vm-sudo-password)"
[ "${HOMELAB_SITE_USED:-}" = vault ] && [ -n "${TF_VAR_site_json:-}" ] ||
  die "site dict not loaded from Vault kv/homelab/site"

# Secrets: "<path under kv/homelab> <key> <host> <extractor> <args...>".
# Extractors (defined in $remote_lib, run as root on the host) print the value with no
# added newline and fail when it is empty.
entries=(
  "frigate/cloudflared token frigate unit_token cloudflared"
  "netbird/cloudflared token netbird unit_token cloudflared"
  "ragnarok/cloudflared token ragnarok unit_token cloudflared"
  "frigate/frigate front_door_rtsp_url frigate yaml /home/config/config.yml cameras.front_door.ffmpeg.inputs.0.path"
  "frigate/frigate rtsp_user frigate url_user /home/config/config.yml cameras.front_door.ffmpeg.inputs.0.path"
  "frigate/frigate rtsp_password frigate url_pass /home/config/config.yml cameras.front_door.ffmpeg.inputs.0.path"
  "frigate/frigate jwt_secret frigate file /home/config/.jwt_secret"
  "frigate/frigate compose_rtsp_password frigate yaml /home/docker-compose.yml services.frigate.environment.FRIGATE_RTSP_PASSWORD"
  "frigate/frigate-notify gotify_token frigate yaml /home/docker-compose.yml services.frigate-notify.environment.GOTIFY_TOKEN"
  "netbird/pulse admin_token netbird dotenv /home/ubuntu/pulse/.env PULSE_ADMIN_TOKEN"
)

# Runs on the VM. Output is the bare value; errors go to stderr and carry no value.
# shellcheck disable=SC2016  # expanded on the VM, not here
remote_lib='
set -euo pipefail
nonempty() { v="$(cat; printf x)"; v="${v%x}"; [ -n "$v" ] || { echo "empty value" >&2; exit 3; }; printf "%s" "$v"; }
# The effective ExecStart (systemd has already dropped comments and quotes); awk reads to EOF.
unit_token() { systemctl show -p ExecStart --value "$1" | awk "!d { for (i = 1; i <= NF; i++) {
  if (\$i == \"--token\" && i < NF) { printf \"%s\", \$(i + 1); d = 1; break }
  if (index(\$i, \"--token=\") == 1) { printf \"%s\", substr(\$i, 9); d = 1; break } } }" | nonempty; }
file() { [ -f "$1" ] || { echo "no file $1" >&2; exit 3; }; nonempty < "$1"; }
dotenv() { sed -n "s/^$2=//p" "$1" | tail -n1 | tr -d "\r\n" | sed -E "s/^\"(.*)\"$/\\1/; s/^'"'"'(.*)'"'"'$/\\1/" | nonempty; }
# Parse errors can quote file content, so the Python stderr is dropped and any failure
# becomes one generic message.
py() { { python3 -I -c "
import sys
try:
    import yaml
    from urllib.parse import urlsplit, unquote
    mode, f, p = sys.argv[1:4]
    v = yaml.safe_load(open(f))
    for k in p.split(\".\"):
        v = v[int(k)] if isinstance(v, list) else v[k]
    v = str(v)
    if mode == \"url_user\": v = unquote(urlsplit(v).username or \"\")
    if mode == \"url_pass\": v = unquote(urlsplit(v).password or \"\")
except BaseException:
    sys.exit(3)
sys.stdout.write(v)
" "$@" 2>/dev/null || { echo "cannot extract $1 $3 from $2" >&2; exit 3; }; } | nonempty; }
yaml() { py yaml "$@"; }
url_user() { py url_user "$@"; }
url_pass() { py url_pass "$@"; }
'

ipof() { printf '%s' "$TF_VAR_site_json" | jq -er --arg h "$1" '.hosts[$h].ip'; }

# Remote wrapper. ssh stdin carries only the sudo password: the login shell reads that one
# line into pw and hands it to `sudo -S` through its own pipe. The code arrives base64 in
# the ssh command (code only, no values) and runs with stdin from /dev/null, so when sudo
# does not prompt (NOPASSWD, cached ticket) the unread password is never executed or read.
# shellcheck disable=SC2016  # expanded on the VM, not here
remote_wrap='IFS= read -r pw || exit 97
code="$(printf %s "$B64" | base64 -d)" || exit 98
printf "%s\n" "$pw" | sudo -S -p "" -- bash -c "exec </dev/null
$code"
rc=$?; unset pw code; exit "$rc"'

# remote <host> <command...>: run "<command>" as root on <host>; stdout is the value.
remote() {
  local ip host=$1 b64; shift
  ip="$(ipof "$host")" || die "no site.hosts.$host.ip"
  b64="$({ printf '%s\n' "$remote_lib"; printf '%q ' "$@"; printf '\n'; } | base64 | tr -d '\n')"
  printf '%s\n' "$ANSIBLE_BECOME_PASSWORD" |
    ssh -o BatchMode=yes -o ConnectTimeout=10 "ubuntu@$ip" "B64=$b64; $remote_wrap"
}

digest() { shasum -a 256 | cut -d' ' -f1; }

# vault_state <path> <key>: "absent-path", "absent-key" or the SHA-256 of the stored value.
vault_state() {
  local out err
  if out="$(vault kv get -format=json -mount=kv "homelab/$1" 2>/dev/null)"; then
    if printf '%s' "$out" | jq -e --arg k "$2" '.data.data | has($k)' >/dev/null; then
      printf '%s' "$out" | jq -j --arg k "$2" '.data.data[$k]' | digest
    else
      echo absent-key
    fi
  else
    err="$(vault kv get -mount=kv "homelab/$1" 2>&1 >/dev/null || true)"
    case $err in
      *"No value found"*) echo absent-path ;;
      *) die "cannot read kv/homelab/$1" ;;
    esac
  fi
}

fail=0
for e in "${entries[@]}"; do
  read -r path key host kind args <<<"$e"
  set -f  # args is a word list on purpose: split it, never glob it
  # shellcheck disable=SC2086
  set -- $args
  set +f
  label="kv/homelab/$path $key"

  src="$(remote "$host" "$kind" "$@" | digest)" || die "$label: cannot read it on $host"
  [ "$src" != "$(printf '' | digest)" ] || die "$label: empty on $host"
  have="$(vault_state "$path" "$key")"

  if [ "$have" = "$src" ]; then
    echo "$label: unchanged (match)"
    continue
  fi
  if [ "$mode" = verify ]; then
    case $have in absent-*) echo "$label: missing" ;; *) echo "$label: differs" ;; esac
    fail=1; continue
  fi
  case $have in
    absent-path) verb="put" ;;
    absent-key) verb="patch" ;;
    *)
      if [ "$mode" != force ]; then
        echo "$label: differs from $host; rerun with --force to replace it" >&2
        fail=1; continue
      fi
      verb="patch" ;;
  esac

  remote "$host" "$kind" "$@" | vault kv "$verb" -mount=kv "homelab/$path" "$key=-" >/dev/null ||
    die "$label: write failed"
  if [ "$(vault_state "$path" "$key")" = "$src" ]; then
    echo "$label: written (match)"
  else
    echo "$label: written (MISMATCH)"; fail=1
  fi
done
exit "$fail"
