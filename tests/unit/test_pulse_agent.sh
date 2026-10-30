#!/usr/bin/env bash
# Pulse agent (role pulse_agent): the settings and apt source render, the netbird VM reports
# on loopback and every other VM to the netbird VM's lab address, and the repository key is
# pinned by its full fingerprint. Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

render() { # render <inventory_hostname> <outdir>
  mkdir -p "$2"
  cat >"$tmp/play.yml" <<PLAY
- name: Pulse agent templates
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: $1
    gateway_domain: internal.example.com
    site: {hosts: {netbird: {ip: 192.0.2.15}, frigate: {ip: 192.0.2.14}}}
  vars_files:
    - $PWD/ansible/roles/pulse_agent/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/pulse_agent/templates/{{ item }}.j2
        dest: $2/{{ item }}
        mode: "0644"
      loop: [agent.env, anvil.sources]
    - ansible.builtin.copy:
        content: "{{ pulse_agent_api_url }}"
        dest: $2/api_url
        mode: "0644"
PLAY
  ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1
}

if render frigate "$tmp/f" && render netbird "$tmp/n"; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
check "a VM reports to the netbird VM's lab address" "grep -qx 'PULSE_SERVER=http://192.0.2.15' '$tmp/f/agent.env'"
check "the netbird VM reports on loopback" "grep -qx 'PULSE_SERVER=http://127.0.0.1' '$tmp/n/agent.env'"
check "every 30 seconds" "grep -qx 'PULSE_INTERVAL=30' '$tmp/f/agent.env'"
check "the agent token is not in the settings file" "! grep -qi token= '$tmp/f/agent.env'"
check "apt source: the lab repository, signed by the pinned keyring" \
  "grep -qx 'URIs: http://192.0.2.15:8082' '$tmp/f/anvil.sources' && grep -qx 'Signed-By: /etc/apt/keyrings/anvil.gpg' '$tmp/f/anvil.sources' && grep -qx 'Suites: stable' '$tmp/f/anvil.sources'"
check "registration goes through the gateway over TLS" "[ \"\$(cat '$tmp/f/api_url')\" = https://pulse.internal.example.com ]"
check "the repository key is pinned by its full 40-digit fingerprint" \
  "grep -qE '^pulse_agent_apt_signer_fpr: [0-9A-F]{40}\$' ansible/roles/pulse_agent/defaults/main.yml"

[ "$fail" = 0 ] && echo "PASS: pulse_agent" || echo "FAIL: pulse_agent"
exit "$fail"
