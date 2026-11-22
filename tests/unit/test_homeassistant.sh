#!/usr/bin/env bash
# Home Assistant (role homeassistant) on the assistant VM: a pinned image, host network so it
# reaches the home IoT over the VM's VPN route, local-first (data stays in the lab, enforced by
# the iot_egress guard), nothing published, a memory cap. Uses no real values. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

r=ansible/roles/homeassistant
d=$r/defaults/main.yml
c=$r/templates/docker-compose.yaml.j2
cfg=$r/templates/configuration.yaml.j2

check "the image is pinned to a digest" "grep -qE '^homeassistant_image:.*@sha256:[0-9a-f]{64}' $d"
check "host network (reaches the home IoT over the VM route)" "grep -q 'network_mode: host' $c"
check "nothing is published to the internet" "! grep -q 'ports:' $c"
check "no new privileges, a memory cap" "grep -q 'no-new-privileges:true' $c && grep -q 'mem_limit:' $c"
check "config is local-first and never logs in to cloud" "grep -qi 'local-first' $cfg && ! grep -qE '^\s*cloud:' $cfg"
check "a play for the assistant VM" "awk '/^- name: Home Assistant$/,0' ansible/playbooks/vms.yml | grep -q 'hosts: assistant_servers'"

check "packages are enabled for code-defined config" "grep -q 'packages: !include_dir_named packages' $cfg"
check "the automations package ships" "test -f $r/files/packages/anvil_automations.yaml && grep -q 'all_off_1am_safety_sweep' $r/files/packages/anvil_automations.yaml"

[ "$fail" = 0 ] && echo "PASS: home assistant" || { echo "FAIL: home assistant"; exit 1; }
