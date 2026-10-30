#!/usr/bin/env bash
# Every host is healthy: no failed systemd unit, no filesystem 95% full, no container
# restarting or unhealthy (tests/smoke/hosts.yml, read-only, run with --check).
source "$(dirname "$0")/lib.sh"
command -v ansible-playbook >/dev/null || skip "ansible-playbook missing"
if smoke_play hosts.yml; then ok "every host is healthy"; else bad_ "every host is healthy"; fi
done_ hosts
