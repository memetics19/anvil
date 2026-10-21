#!/usr/bin/env bash
# Pi-hole local records (ansible/roles/pihole/tasks/records.yml), run locally with a
# fixture site dict: `name` goes under the lan zone, `fqdn` is served as is (split
# horizon), `ref` and `ip` give the address; malformed entries fail the run.
# Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  got:  $2"; echo "  want: $3"; fail=1; fi; }

# run <records-json> -> writes $tmp/out (one line per record) and returns the play's exit code
run() {
  cat >"$tmp/play.yml" <<PLAY
- name: Records test
  hosts: localhost
  gather_facts: false
  vars:
    site:
      domain: example.com
      pve: {ip: 192.0.2.10, uplink_ip: 198.51.100.250}
      hosts:
        vault: {ip: 192.0.2.120}
        apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}
    pihole_local_records: $1
  tasks:
    - name: Records
      ansible.builtin.include_role:
        name: pihole
        tasks_from: records.yml
    - name: Write them out
      ansible.builtin.copy:
        content: "{{ pihole_hosts | join('\n') }}\n"
        dest: "$tmp/out"
        mode: "0600"
PLAY
  rm -f "$tmp/out"
  ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1
}

run '[{name: vault, ref: hosts.vault.ip}, {name: pve, ref: pve.uplink_ip}, {fqdn: vw.example.com, ref: hosts.apps.home_ip}, {fqdn: "NB.Example.com.", ip: 198.51.100.7}, {name: printer, ip: 198.51.100.40}]'
check "good records render" "$?" 0
check "name under lan zone, ref, fqdn as is (lower case, no trailing dot), ip" "$(cat "$tmp/out" 2>/dev/null)" \
"192.0.2.120 vault.lan.example.com
198.51.100.250 pve.lan.example.com
198.51.100.249 vw.example.com
198.51.100.7 nb.example.com
198.51.100.40 printer.lan.example.com"

bad() {
  run "$2"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'site.dns.local_records' "$tmp/log"; then echo "ok   rejects $1"
  else echo "FAIL accepts $1 (rc $rc)"; fail=1; fi
}
bad "both name and fqdn"   '[{name: a, fqdn: a.example.com, ip: 198.51.100.1}]'
bad "neither name nor fqdn" '[{ip: 198.51.100.1}]'
bad "missing address"       '[{name: a}]'
bad "ref to nothing"        '[{name: a, ref: hosts.nope.ip}]'
bad "ref to a non-address"  '[{name: a, ref: domain}]'
bad "fqdn without a dot"    '[{fqdn: vw, ip: 198.51.100.1}]'
bad "upper-case name"       '[{name: Vault, ip: 198.51.100.1}]'
bad "same name twice"       '[{name: a, ip: 198.51.100.1}, {fqdn: a.lan.example.com, ip: 198.51.100.2}]'

[ "$fail" -eq 0 ] && echo "PASS: pihole records"
exit "$fail"
