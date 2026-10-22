#!/usr/bin/env bash
# Pi-hole local records (ansible/roles/pihole/tasks/records.yml), run locally with a
# fixture site dict: `name` goes under the lan zone, `fqdn` is served as is (split
# horizon), `ref` and `ip` give the address; malformed entries fail the run. Also the DNS
# network check (tasks/dns_network.yml): RFC 1918, no overlap with the lab or home network,
# NetBird's range or Docker's default bridge, Unbound's address inside.
# Uses documentation-range addresses and example.com; private addresses are assembled at
# run time so this file holds no private literal (gitleaks rule private-ipv4).
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

# --- DNS network ---------------------------------------------------------------------------
p10="10."; p172="172."; p192="192.""168."
# net <subnet> <unbound ip> -> exit code of the play (lab p10 2.0.0/24, home p192 100.0/24)
net() {
  cat >"$tmp/net.yml" <<PLAY
- name: DNS network test
  hosts: localhost
  gather_facts: false
  vars:
    site:
      lan_cidr: ${p10}2.0.0/24
      pve: {uplink_ip: ${p192}100.250, uplink_prefix: 24}
    pihole_dns_subnet: "$1"
    pihole_unbound_ip: "$2"
  tasks:
    - name: Check
      ansible.builtin.include_role:
        name: pihole
        tasks_from: dns_network.yml
PLAY
  ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$tmp/net.yml" >"$tmp/log" 2>&1
}
net "${p172}31.53.0/24" "${p172}31.53.53"; check "DNS network: private, no overlap" "$?" 0
badnet() {
  net "$2" "$3"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$4" "$tmp/log"; then echo "ok   DNS network rejects $1"
  else echo "FAIL DNS network accepts $1 (rc $rc)"; fail=1; fi
}
badnet "a public range"         198.51.100.0/24        198.51.100.53        "RFC 1918"
badnet "overlap with the lab"   "${p10}2.0.0/16"       "${p10}2.9.53"       "overlaps the lab network"
badnet "overlap with home"      "${p192}100.128/25"    "${p192}100.153"     "overlaps the home network"
badnet "Docker's bridge"        "${p172}17.5.0/24"     "${p172}17.5.53"     "overlaps Docker"
badnet "Unbound outside"        "${p172}31.53.0/24"    "${p172}31.54.53"    "not inside dns_subnet"
badnet "too large a prefix"     "${p10}0.0.0/8"        "${p10}9.0.53"       "prefix must be"

# Live FTL settings: the rate limit is applied with pihole-FTL --config, never through the
# compose environment (a change there recreates Pi-hole, and FTL makes env values read-only).
r=ansible/roles/pihole
check "rate limit not in the compose environment" "$(grep -c 'FTLCONF_dns_rateLimit' "$r/templates/docker-compose.yaml.j2")" 0
check "rate limit applied live" "$(grep -cE '^  dns\.rateLimit\.(count|interval): ' "$r/defaults/main.yml")" 2
check "live settings: read, write only what differs, read back" \
  "$(grep -cE 'pihole-FTL, --config' "$r/tasks/settings_apply.yml")" 3
check "no live setting is also an FTLCONF_ variable" \
  "$(sed -n 's/^  \([a-zA-Z.]*\): .*/\1/p' "$r/defaults/main.yml" | grep '\.' | tr '.' '_' | while read -r k; do grep -c "FTLCONF_$k" "$r/templates/docker-compose.yaml.j2"; done | sort -u | tr -d '\n')" 0

[ "$fail" -eq 0 ] && echo "PASS: pihole records and DNS network"
exit "$fail"
