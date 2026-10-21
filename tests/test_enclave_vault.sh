#!/usr/bin/env bash
# Vault in the secrets enclave, run locally with a fixture site dict: the Vault config with
# its transition listener (role vault_server), the enclave netplan (role guest_base, enclave
# mode) with and without the old lab NIC, and the group variables that drive both.
# Uses documentation-range addresses and example MACs only.
# The checks are eval strings, expanded when they run.
# shellcheck disable=SC2016,SC2034,SC2329
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# render <name> <extra vault keys, yaml flow fragment>
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: Enclave vault test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/vault_server/defaults/main.yml
    - $PWD/ansible/inventory/group_vars/vault_servers.yml
  vars:
    inventory_hostname: vault
    site:
      lan_cidr: 192.0.2.0/24
      sdn: {enclave: {subnet: 203.0.113.0/24, gateway: 203.0.113.1}}
      hosts:
        vault: {ip: 203.0.113.20, vmid: 9004, mac: "02:00:00:00:00:07", enclave_mac: "02:00:00:00:00:08"$2}
  tasks:
    - name: Files
      ansible.builtin.template:
        src: "$PWD/ansible/roles/{{ item.src }}"
        dest: "$tmp/$1-{{ item.dest }}"
        mode: "0600"
      loop:
        - {src: vault_server/templates/vault.hcl.j2, dest: vault.hcl}
        - {src: guest_base/templates/netplan-enclave.yaml.j2, dest: netplan.yaml}
    - name: Variables
      ansible.builtin.copy:
        content: "{{ {'repo': vault_server_apt_repo, 'extra': vault_server_extra_ips} | to_json }}"
        dest: "$tmp/$1-vars.json"
        mode: "0600"
PLAY
  ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local -e ansible_become=false "$tmp/play.yml" >"$tmp/$1.log" 2>&1
}

yaml_ok() { python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$1" 2>/dev/null || ruby -ryaml -e "YAML.safe_load(File.read(ARGV[0]))" "$1"; }

# 1. During the move: the lab NIC is kept.
render move ', lab_ip: 192.0.2.120'
if [ -s "$tmp/move-vault.hcl" ]; then ok "move: renders"; else bad_ "move: renders"; tail -20 "$tmp/move.log"; fi
h=$tmp/move-vault.hcl n=$tmp/move-netplan.yaml
check "move: api_addr on the enclave"        'grep -qx "api_addr     = \"https://203.0.113.20:8200\"" "$h"'
check "move: cluster_addr on the enclave"    'grep -qx "cluster_addr = \"https://203.0.113.20:8201\"" "$h"'
check "move: listeners on both addresses"    '[ "$(grep -c "^listener \"tcp\"" "$h")" = 2 ] && grep -q "address         = \"192.0.2.120:8200\"" "$h"'
check "move: one cluster listener"           '[ "$(grep -c "cluster_address" "$h")" = 1 ]'
check "move: no HashiCorp repository"        'jq -e ".repo == false" "$tmp/move-vars.json"'
check "move: lab address as extra listener"  'jq -e ".extra == [\"192.0.2.120\"]" "$tmp/move-vars.json"'
check "move: netplan is YAML"                'yaml_ok "$n"'
check "move: lab NIC kept, by MAC, as eth0"  'grep -q "macaddress: \"02:00:00:00:00:07\"" "$n" && grep -q "set-name: eth0" "$n" && grep -q "192.0.2.120/24" "$n"'
check "move: default route on the enclave"   '[ "$(grep -c "to: default" "$n")" = 1 ] && grep -q "via: 203.0.113.1" "$n"'
check "move: enclave NIC by MAC"             'grep -q "macaddress: \"02:00:00:00:00:08\"" "$n" && grep -q "203.0.113.20/24" "$n"'
check "move: no DNS servers"                 '! grep -q nameservers "$n"'

# 2. After the lab NIC is retired.
render retired ', lab_ip: 192.0.2.120, lab_nic_retired: true'
h=$tmp/retired-vault.hcl n=$tmp/retired-netplan.yaml
check "retired: renders"                     '[ -s "$h" ]'
check "retired: one listener"                '[ "$(grep -c "^listener \"tcp\"" "$h")" = 1 ] && ! grep -q 192.0.2.120 "$h"'
check "retired: lab NIC kept with no address" 'grep -q "02:00:00:00:00:07" "$n" && ! grep -q 192.0.2.120 "$n" && grep -q "link-local: \[\]" "$n"'
check "retired: lab NIC optional (boot does not wait)" 'grep -q "optional: true" "$n"'
check "retired: netplan is YAML"             'yaml_ok "$n"'

exit "$fail"
