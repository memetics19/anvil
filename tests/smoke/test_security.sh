#!/usr/bin/env bash
# No host shows a sign of intrusion or a weak spot: unknown SSH keys or listeners, password
# SSH, programs in temporary directories, miners, privileged containers, changed system
# files, password guessing, security updates off (tests/smoke/security.yml, read-only).
source "$(dirname "$0")/lib.sh"
command -v ansible-playbook >/dev/null || skip "ansible-playbook missing"
if smoke_play security.yml; then ok "every host passes the security checks"; else bad_ "every host passes the security checks"; fi
done_ security
