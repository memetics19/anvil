#!/usr/bin/env bash
# Port guard (role port_guard) and the ARR apps' logins (role arr_stack, tasks/logins.yml):
# the nftables rules allow only the containers, the gateway and Pulse to the guarded ports,
# and the apps' logins go off only when the guard closes every app port.
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: Port guard
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/port_guard/defaults/main.yml
    - $PWD/ansible/inventory/host_vars/ragnarok.yml
  vars:
    inventory_hostname: ragnarok
    site:
      hosts:
        ragnarok: {ip: 192.0.2.119}
        apps: {ip: 192.0.2.121}
        netbird: {ip: 192.0.2.115}
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/port_guard/templates/port-guard.nft.j2
        dest: $tmp/guard.nft
        mode: "0600"
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1; then ok "the guard renders"; else
  bad_ "the guard renders"; cat "$tmp/log"; exit 1; fi
g=$tmp/guard.nft
check "replies pass first" "grep -qx $'\t\tct state established,related accept' '$g'"
check "the VM's own containers pass" "grep -qx $'\t\tiifname \"docker0\" accept' '$g' && grep -qx $'\t\tiifname \"br-\*\" accept' '$g'"
check "only the gateway and Pulse pass from outside" "grep -qx $'\t\tip saddr { 192.0.2.121, 192.0.2.115 } accept' '$g'"
check "the ARR web ports on the VM's address are dropped for everyone else, not the torrent port" \
  "grep -qx $'\t\tmeta l4proto tcp ct original ip daddr 192.0.2.119 ct original proto-dst { 8989, 7878, 9696, 9117, 8080 } counter drop' '$g' && ! grep -q 6881 '$g'"
check "the table replaces itself in one load" "grep -qx 'delete table inet anvil_port_guard' '$g'"
check "nothing but the guard's own drop" "[ \$(grep -v '^[[:space:]]*#' '$g' | grep -c drop) = 1 ]"

# The logins go off only behind the guard.
check "ragnarok: logins off, and every login port is guarded" \
  "python3 -c 'import yaml; h=yaml.safe_load(open(\"ansible/inventory/host_vars/ragnarok.yml\")); d=yaml.safe_load(open(\"ansible/roles/arr_stack/defaults/main.yml\"))
assert h[\"arr_stack_app_logins\"] is False and d[\"arr_stack_app_logins\"] is True
assert set(d[\"arr_stack_login_ports\"]) <= set(h[\"port_guard_ports\"])'"
check "logins.yml refuses logins off without the guard, first" \
  "python3 -c 'import yaml; t=yaml.safe_load(open(\"ansible/roles/arr_stack/tasks/logins.yml\")); a=t[0]
assert \"ansible.builtin.assert\" in a and \"port_guard_ports\" in a[\"ansible.builtin.assert\"][\"that\"]'"
check "vms.yml: the guard runs before the ARR stack" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/vms.yml\")); r=[x for x in p if x[\"name\"]==\"Ragnarok workloads\"][0][\"roles\"]
n=[x[\"role\"] for x in r]; assert n.index(\"port_guard\") < n.index(\"arr_stack\")'"

[ "$fail" -eq 0 ] && echo "PASS: port guard"
exit "$fail"
