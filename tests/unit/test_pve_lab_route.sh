#!/usr/bin/env bash
# pve_lab_route: the other cluster members get the lab network via the main host's home address
# from a boot-time unit (their network configuration is not edited), and the default route is
# left alone. Documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/pve_lab_route

cat >"$tmp/play.yml" <<PLAY
- name: Render the unit
  hosts: localhost
  gather_facts: false
  vars:
    pve_lab_route_cidr: 192.0.2.0/24
    pve_lab_route_via: 198.51.100.250
    pve_lab_route_dev: vmbr0
  tasks:
    - ansible.builtin.template: {src: $r/templates/anvil-lab-route.service.j2, dest: $tmp/unit, mode: "0644"}
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1; then ok "unit renders"; else bad_ "unit renders"; cat "$tmp/log"; exit 1; fi
u=$tmp/unit

check "adds the lab route via the main host at boot" "grep -qx 'ExecStart=/usr/sbin/ip route replace 192.0.2.0/24 via 198.51.100.250 dev vmbr0' '$u' && grep -qx 'WantedBy=multi-user.target' '$u' && grep -qx 'After=network-online.target' '$u'"
check "never touches the default route" "! grep -q 'default' '$u'"
check "defaults come from the main host's site dict" "grep -q \"site.lan_cidr\" $r/defaults/main.yml && grep -q \"site.pve.uplink_ip\" $r/defaults/main.yml"
check "only on the other cluster members" "grep -A3 '^- name: Cluster members. route to the lab' ansible/playbooks/host.yml | grep -q 'hosts: cluster_members'"
check "it checks the lab is reached via the main host" "grep -q 'via \" ~ pve_lab_route_via' $r/tasks/main.yml"

[ "$fail" = 0 ] && echo "PASS: pve lab route" || echo "FAIL: pve lab route"
exit "$fail"
