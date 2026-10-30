#!/usr/bin/env bash
# The TCP options guard (role tcp_options_guard, CVE-2026-98432): the rendered ruleset drops
# IPv4 TCP with IP options on prerouting before conntrack and nothing else, and every VM,
# the Proxmox host and the other cluster members get it. Renders locally, needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: Render the guard
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/tcp_options_guard/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/tcp_options_guard/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0644"
      loop: [tcp-options-guard.nft, tcp-options-guard.service]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
g=$tmp/tcp-options-guard.nft
rules=$(grep -vE '^\s*(#|$)' "$g")

check "one table, replaced in one transaction" \
  "[ \"\$(grep -c '^table inet anvil_tcp_options_guard' '$g')\" = 2 ] && grep -q '^delete table inet anvil_tcp_options_guard' '$g'"
check "on prerouting at raw priority, so before conntrack, routing and Docker" \
  "grep -q 'type filter hook prerouting priority raw; policy accept;' '$g'"
check "drops IPv4 TCP whose header is longer than 5 words (IP options)" \
  "grep -qx $'\t\tip protocol tcp ip hdrlength != 5 counter drop' '$g'"
check "drops nothing else" "[ \"\$(grep -c 'drop' <<<\"\$rules\")\" = 1 ] && ! grep -q 'accept' <<<\"\$(grep -v policy <<<\"\$rules\")\""
check "the boot unit loads it before the network" \
  "grep -q '^Before=network-pre.target' '$tmp/tcp-options-guard.service' && grep -q '^ExecStart=/usr/sbin/nft -f /etc/anvil/tcp-options-guard.nft' '$tmp/tcp-options-guard.service'"

check "every VM gets it, the enclave's too" "python3 -c '
import yaml
plays = yaml.safe_load(open(\"ansible/playbooks/vms.yml\"))
p = [p for p in plays if any(isinstance(r, dict) and r.get(\"role\") == \"tcp_options_guard\" for r in p.get(\"roles\", []))]
assert len(p) == 1
groups = set(p[0][\"hosts\"].split(\":\"))
assert {\"guests\", \"vault_servers\", \"apps_servers\", \"vaultwarden_servers\", \"identity_servers\", \"llm_servers\"} <= groups, groups
'"
check "the Proxmox host and the other cluster members get it" "python3 -c '
import yaml
plays = yaml.safe_load(open(\"ansible/playbooks/host.yml\"))
hosts = [p[\"hosts\"] for p in plays if any(isinstance(r, dict) and r.get(\"role\") == \"tcp_options_guard\" for r in p.get(\"roles\", []))]
assert \"proxmox\" in hosts and \"cluster_members\" in hosts, hosts
'"

[ "$fail" = 0 ] && echo "PASS: tcp_options_guard"
exit "$fail"
