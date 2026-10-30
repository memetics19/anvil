#!/usr/bin/env bash
# Plays send the become password and secrets from Vault, so SSH must check host keys.
# Fails when ansible.cfg turns checking off, or when anything in the repo disables it.
# That includes pointing the switch's known hosts file at /dev/null (or none): with
# accept-new, an empty file accepts any key every time.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

bad=0
fail() { echo "FAIL: $*"; bad=1; }

grep -Eq '^host_key_checking *= *True' ansible/ansible.cfg ||
  fail "ansible/ansible.cfg must set host_key_checking = True"
grep -Eq '^ssh_args *=.*StrictHostKeyChecking=(accept-new|yes)' ansible/ansible.cfg ||
  fail "ansible/ansible.cfg ssh_args must set StrictHostKeyChecking=accept-new (or yes)"

off='StrictHostKeyChecking[= ]+(no|off)|host_key_checking *[:=] *(False|false|no)|HOST_KEY_CHECKING=(False|false|0)|UserKnownHostsFile[= ]+/dev/null'
off+="|(SWITCH_KNOWN_HOSTS|network_switch_known_hosts) *[:=] *[\"']?(/dev/null|none)([\"' ]|\$)"

# Self-test: each of these lines turns checking off and must be caught.
while IFS= read -r l; do
  printf '%s\n' "$l" | grep -Eq "$off" || fail "the pattern misses: $l"
done <<'LINES'
host_key_checking = False
ssh -o StrictHostKeyChecking=no host
ssh -o UserKnownHostsFile=/dev/null host
SWITCH_KNOWN_HOSTS=/dev/null
export SWITCH_KNOWN_HOSTS="/dev/null"
SWITCH_KNOWN_HOSTS=none make switch
    SWITCH_KNOWN_HOSTS: /dev/null
network_switch_known_hosts: "/dev/null"
LINES

hits=$(git ls-files -z | xargs -0 grep -n -I -E "$off" -- 2>/dev/null | grep -v '^tests/unit/test_host_keys.sh:')
[ -z "$hits" ] || fail "host key checking is turned off here:"$'\n'"$hits"

# OpenSSH does not pass command-line -o options to a ProxyJump host, so ansible.cfg's
# accept-new never reaches the jump. A jump must be a ProxyCommand that sets it itself.
# Comment lines are skipped.
jumps=$(git ls-files -z ansible | xargs -0 grep -n -I -E 'ProxyJump[= ]|ProxyCommand' -- 2>/dev/null |
  grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#' | grep -v -E 'ProxyCommand.*StrictHostKeyChecking=(accept-new|yes)')
[ -z "$jumps" ] || fail "a jump host must check its key: use a ProxyCommand with ssh -o StrictHostKeyChecking=accept-new -W %h:%p:"$'\n'"$jumps"

if [ "$bad" = 0 ]; then echo "PASS: SSH host keys are checked"; fi
exit "$bad"
