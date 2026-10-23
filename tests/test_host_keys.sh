#!/usr/bin/env bash
# Plays send the become password and secrets from Vault, so SSH must check host keys.
# Fails when ansible.cfg turns checking off, or when anything in the repo disables it.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

bad=0
fail() { echo "FAIL: $*"; bad=1; }

grep -Eq '^host_key_checking *= *True' ansible/ansible.cfg ||
  fail "ansible/ansible.cfg must set host_key_checking = True"
grep -Eq '^ssh_args *=.*StrictHostKeyChecking=(accept-new|yes)' ansible/ansible.cfg ||
  fail "ansible/ansible.cfg ssh_args must set StrictHostKeyChecking=accept-new (or yes)"

hits=$(git ls-files -z | xargs -0 grep -n -I -E \
  'StrictHostKeyChecking[= ]+(no|off)|host_key_checking *[:=] *(False|false|no)|HOST_KEY_CHECKING=(False|false|0)|UserKnownHostsFile[= ]+/dev/null' \
  -- 2>/dev/null | grep -v '^tests/test_host_keys.sh:')
[ -z "$hits" ] || fail "host key checking is turned off here:"$'\n'"$hits"

if [ "$bad" = 0 ]; then echo "PASS: SSH host keys are checked"; fi
exit "$bad"
