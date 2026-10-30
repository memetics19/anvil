#!/usr/bin/env bash
# scripts/forget-host.sh (make forget-host), run locally against throwaway known_hosts files.
# A stub ansible on PATH answers for a small fake inventory. Checks that only one inventory
# host is accepted, that the switch's key goes from its own file, that ssh-keygen errors
# are not swallowed and that the output says what was removed.
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  got:  $2"; echo "  want: $3"; fail=1; fi; }

# The stub prints what the ansible.posix.json callback prints for the debug task: one entry
# per matched host, msg "<kind> <address>".
mkdir "$tmp/bin"
cat >"$tmp/bin/ansible" <<'STUB'
#!/usr/bin/env bash
host() { printf '"%s": {"changed": false, "failed": %s, "msg": "%s"}' "$1" "$2" "$3"; }
case "$1" in
  frigate) hosts=$(host frigate false "ssh 192.0.2.10") ;;
  switch) hosts=$(host switch false "switch 192.0.2.24") ;;
  localbox) hosts=$(host localbox false "local localbox") ;;
  guests) hosts="$(host frigate false "ssh 192.0.2.10"), $(host netbird false "ssh 192.0.2.11")" ;;
  vaultwarden_servers) hosts=$(host vaultwarden false "ssh 192.0.2.12") ;;
  broken) hosts=$(host broken true "site is undefined"); rc=2 ;;
  *) echo "[WARNING]: Could not match supplied host pattern, ignoring: $1" >&2
     printf '{"plays": [{"tasks": []}], "stats": {}}\n'; exit 0 ;;
esac
printf '{"plays": [{"tasks": [{"hosts": {%s}}]}], "stats": {}}\n' "$hosts"
exit "${rc:-0}"
STUB
chmod +x "$tmp/bin/ansible"

ssh-keygen -q -t ed25519 -N '' -C '' -f "$tmp/key" >/dev/null
pub=$(cut -d' ' -f1,2 "$tmp/key.pub")
fp=$(ssh-keygen -l -f "$tmp/key.pub" | cut -d' ' -f2)
mkdir "$tmp/ssh" "$tmp/switch"
ssh_kh="$tmp/ssh/known_hosts"
sw_kh="$tmp/switch/known_hosts"
reset() {
  printf '192.0.2.10 %s\n192.0.2.11 %s\n192.0.2.24 %s\n' "$pub" "$pub" "$pub" >"$ssh_kh"
  printf '192.0.2.24 %s\n' "$pub" >"$sw_kh"
  rm -f "$ssh_kh.old" "$sw_kh.old"
}
forget() {
  PATH="$tmp/bin:$PATH" FORGET_HOST_KNOWN_HOSTS="$ssh_kh" SWITCH_KNOWN_HOSTS="$sw_kh" \
    scripts/forget-host.sh "$@" >"$tmp/out" 2>&1
}
hosts_in() { cut -d' ' -f1 "$1" | tr '\n' ' '; }

reset
forget frigate
check "ssh host: rc" "$?" 0
check "ssh host: only its key is gone" "$(hosts_in "$ssh_kh")" "192.0.2.11 192.0.2.24 "
check "ssh host: says what it removed" "$(grep -c "192.0.2.10 ED25519 $fp" "$tmp/out")" 1
check "ssh host: the switch file is untouched" "$(hosts_in "$sw_kh")" "192.0.2.24 "

forget frigate
check "ssh host again: rc" "$?" 0
check "ssh host again: says no key was stored" "$(grep -c 'no key stored' "$tmp/out")" 1
check "ssh host again: never says removed" "$(grep -c 'removed' "$tmp/out")" 0

reset
forget switch
check "switch: rc" "$?" 0
check "switch: its key is gone from the switch file" "$(hosts_in "$sw_kh")" ""
check "switch: ~/.ssh/known_hosts is untouched" "$(hosts_in "$ssh_kh")" "192.0.2.10 192.0.2.11 192.0.2.24 "
check "switch: says what it removed" "$(grep -c "192.0.2.24 ED25519 $fp" "$tmp/out")" 1

rm -f "$sw_kh"
forget switch
check "switch, no file yet: rc" "$?" 0
check "switch, no file yet: says no key was stored" "$(grep -c 'no key stored' "$tmp/out")" 1

for h in guests vaultwarden_servers nosuch localbox broken 'fri*' 'frigate,netbird' ''; do
  reset
  forget "$h"
  check "refuses '$h': rc 1" "$?" 1
  check "refuses '$h': nothing removed" "$(hosts_in "$ssh_kh")|$(hosts_in "$sw_kh")" \
    "192.0.2.10 192.0.2.11 192.0.2.24 |192.0.2.24 "
  check "refuses '$h': never says removed" "$(grep -c 'removed' "$tmp/out")" 0
done
forget
check "no argument: rc 2" "$?" 2

# ssh-keygen -R cannot write its new file in a read-only directory: the error must show.
reset
chmod a-w "$tmp/ssh"
forget frigate
rc=$?
chmod u+w "$tmp/ssh"
if [ "$(id -u)" != 0 ]; then
  check "ssh-keygen error: rc 1" "$rc" 1
  check "ssh-keygen error: never says removed" "$(grep -c '^forget-host: removed' "$tmp/out")" 0
  check "ssh-keygen error: the key is still there" "$(hosts_in "$ssh_kh")" "192.0.2.10 192.0.2.11 192.0.2.24 "
fi

exit "$fail"
