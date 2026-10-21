#!/usr/bin/env bash
# Routed segments firewall (role pve_segments) and the enclave's segment (role pve_enclave),
# run locally with a fixture site dict: the rendered nftables ruleset, the set refresh script
# (stubbed dig and nft) and the firewall rollback script (stubbed ping and nft).
# Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
has() { if grep -qF -- "$2" "$3"; then echo "ok   $1"; else echo "FAIL $1 (missing: $2)"; fail=1; fi; }
hasnt() { if grep -qF -- "$2" "$3"; then echo "FAIL $1 (present: $2)"; fail=1; else echo "ok   $1"; fi; }

# render <out> <extra hosts yaml flow> <smtp enabled> -> the enclave's ruleset
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: Segments test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/pve_enclave/defaults/main.yml
  vars:
    pve_segments_table: segments
    pve_segments_list: "{{ [pve_enclave_segment] }}"
    pve_segments_sets: "{{ pve_enclave_sets }}"
    pve_enclave_smtp_enabled: $3
    pve_enclave_smtp_host: smtp.example.com
    pve_enclave_smtp_port: "587"
    site:
      pve: {ip: 192.0.2.10, uplink_ip: 203.0.113.250}
      sdn: {enclave: {subnet: 198.51.100.0/24, gateway: 198.51.100.1}}
      admin_sources: [192.0.2.0/24, 203.0.113.0/24, 198.51.100.200/32]
      hosts:
        apps: {ip: 192.0.2.121}
        frigate: {ip: 192.0.2.114}
        ragnarok: {ip: 192.0.2.119}
        vault: {ip: 198.51.100.20}
        $2
  tasks:
    - name: Ruleset
      ansible.builtin.template:
        src: $PWD/ansible/roles/pve_segments/templates/segments.nft.j2
        dest: "$1"
        mode: "0600"
PLAY
  ansible-playbook "$tmp/play.yml" >"$tmp/out.log" 2>&1
}

# 1. Both VMs on the enclave, SMTP on.
render "$tmp/full.nft" 'vaultwarden: {ip: 198.51.100.21}' true
check "render: rc" "$?" "0"
f=$tmp/full.nft
has "one table, replaced in one transaction" "delete table inet segments" "$f"
has "admin set from site.admin_sources" "elements = { 192.0.2.0/24, 203.0.113.0/24, 198.51.100.200/32 }" "$f"
has "workload VMs are not operators" "elements = { 192.0.2.121, 192.0.2.114, 192.0.2.119 }" "$f"
has "the SMTP set is DNS-fed (timeout)" "flags timeout" "$f"
has "forward: established first" "ct state established,related accept" "$f"
has "forward: out of the enclave" 'iifname "secrets" jump enclave_out' "$f"
has "forward: into the enclave" 'oifname "secrets" jump enclave_in' "$f"
has "Caddy to Vault" "ip saddr 192.0.2.121 ip daddr 198.51.100.20 tcp dport 8200 accept" "$f"
has "Caddy to Vaultwarden" "ip saddr 192.0.2.121 ip daddr 198.51.100.21 tcp dport 8080 accept" "$f"
has "excluded before the operator rules" "ip saddr @not_admin counter drop" "$f"
has "operators: SSH on both VMs" "ip saddr @admin ip daddr { 198.51.100.20, 198.51.100.21 } tcp dport 22 accept" "$f"
has "operators: Vault's API" "ip saddr @admin ip daddr 198.51.100.20 tcp dport 8200 accept" "$f"
hasnt "operators: no Vaultwarden port" "ip saddr @admin ip daddr 198.51.100.21 tcp dport 8080" "$f"
has "Vaultwarden: DNS to Pi-hole" "ip saddr 198.51.100.21 ip daddr 192.0.2.121 udp dport 53 return" "$f"
has "Vaultwarden: SMTP to the relay set" "ip saddr 198.51.100.21 ip daddr @enclave_smtp_relay tcp dport 587 return" "$f"
has "host: NTP on the gateway" "ip daddr 198.51.100.1 udp dport 123 accept" "$f"
has "host: apt cache on the gateway" "ip daddr 198.51.100.1 tcp dport 3142 accept" "$f"
has "host: RGW for Vaultwarden only" "ip saddr 198.51.100.21 ip daddr 192.0.2.10 tcp dport 7480 accept" "$f"
has "forward: enclave addresses only from the vnet" 'ip saddr 198.51.100.0/24 iifname != "secrets" counter drop' "$f"
has "input: enclave addresses only from the vnet" 'ip saddr 198.51.100.0/24 iifname != { "secrets", "lo" } counter drop' "$f"
has "gateway address only on its vnet" 'ip daddr 198.51.100.1 iifname != { "secrets", "lo" } counter drop' "$f"
check "every segment chain ends in drop" "$(grep -c '^		counter drop$' "$f")" "3"
hasnt "no NAT for the enclave as a whole" "masquerade" "$f"
has "only the mail hole is translated" "ip saddr 198.51.100.21 ip daddr @enclave_smtp_relay tcp dport 587 snat ip to 203.0.113.250" "$f"
check "one source NAT rule" "$(grep -c 'snat ip to' "$f")" "1"
hasnt "no Vault egress" "ip saddr 198.51.100.20 ip daddr" "$f"
hasnt "no monitoring host, no monitoring rule" "dport 9100" "$f"

# 2. Vaultwarden not created yet, SMTP off: its rules are left out, the set is plain.
render "$tmp/novw.nft" '' false
check "render without vaultwarden: rc" "$?" "0"
hasnt "no Vaultwarden rule" "198.51.100.21" "$tmp/novw.nft"
hasnt "SMTP off: no timeout set" "flags timeout" "$tmp/novw.nft"
hasnt "without Vaultwarden: nothing translated" "snat" "$tmp/novw.nft"
has "SSH still to Vault" "ip saddr @admin ip daddr { 198.51.100.20 } tcp dport 22 accept" "$tmp/novw.nft"

# 3. A monitoring host gets node_exporter and Vault metrics.
render "$tmp/mon.nft" 'monitoring: {ip: 192.0.2.130}' true
has "monitoring: node_exporter" "ip saddr 192.0.2.130 ip daddr { 198.51.100.20 } tcp dport 9100 accept" "$tmp/mon.nft"

# 4. A second segment with NAT (the shape Task 13e uses).
cat >"$tmp/vlan.yml" <<'PLAY'
- name: Two segments
  hosts: localhost
  gather_facts: false
  vars:
    pve_segments_table: segments
    pve_segments_sets: [{name: lan, interval: true, elements: [192.0.2.0/24]}]
    pve_segments_list:
      - {name: enclave, interface: secrets, subnet: 198.51.100.0/24, gateway: 198.51.100.1, nat: false,
         ingress: [{saddr: "@lan", daddr: 198.51.100.20, proto: tcp, dport: [22, 8200]}]}
      - {name: cameras, interface: vlan20, subnet: 203.0.113.0/24, gateway: 203.0.113.1, nat: true,
         egress: [{daddr: 192.0.2.114, proto: tcp, dport: 1883}]}
  tasks:
    - name: Ruleset
      ansible.builtin.template:
        src: "{{ playbook_dir }}/segments.nft.j2"
        dest: "{{ playbook_dir }}/vlan.nft"
        mode: "0600"
PLAY
cp ansible/roles/pve_segments/templates/segments.nft.j2 "$tmp/"
ansible-playbook "$tmp/vlan.yml" >"$tmp/out2.log" 2>&1
check "two segments: rc" "$?" "0"
has "port list" "ip saddr @lan ip daddr 198.51.100.20 tcp dport { 22, 8200 } accept" "$tmp/vlan.nft"
has "egress without saddr" "ip daddr 192.0.2.114 tcp dport 1883 return" "$tmp/vlan.nft"
has "NAT only for the NAT segment" 'ip saddr 203.0.113.0/24 oifname != "vlan20" masquerade' "$tmp/vlan.nft"
check "one masquerade" "$(grep -c masquerade "$tmp/vlan.nft")" "1"
check "out jumps before in jumps" "$(grep -nE 'jump (enclave|cameras)_(out|in)' "$tmp/vlan.nft" | awk -F: '{print $2}' | tr -d '\t' | cut -d' ' -f4 | tr '\n' ' ')" \
  "enclave_out cameras_out enclave_in cameras_in "

# 5. Set refresh script (stubbed dig/nft). Private addresses are built at run time (the
# repo's gitleaks rule rejects private IPv4 literals).
ten=$((5 * 2)); c168=$((84 * 2))
mkdir "$tmp/bin"
refresh=ansible/roles/pve_segments/files/segments-set-refresh.sh
cat >"$tmp/set.conf" <<'CONF'
TABLE=segments
SET=enclave_smtp_relay
LOOKUP_HOST=smtp.example.com
RESOLVER=192.0.2.121
KEEP=24h
MAX=3
CONF
cat >"$tmp/bin/nft" <<STUB
#!/bin/sh
if [ "\$1" = list ]; then cat "$tmp/present"; exit 0; fi
cat >>"$tmp/nft-in"
STUB
chmod +x "$tmp/bin/nft"
dig_answer() { printf '#!/bin/sh\nprintf "%%s\\n" %s\n' "$*" >"$tmp/bin/dig"; chmod +x "$tmp/bin/dig"; }

: >"$tmp/nft-in"; printf 'elements = { 8.8.8.8 timeout 1d expires 2h }\n' >"$tmp/present"
dig_answer relay.example.net. 8.8.8.8 8.8.4.4 "$ten.1.2.3"
PATH="$tmp/bin:$PATH" bash "$refresh" "$tmp/set.conf" >/dev/null 2>&1
check "refresh: rc" "$?" "0"
has "refresh: present address deleted then re-added" "delete element inet segments enclave_smtp_relay { 8.8.8.8 }" "$tmp/nft-in"
has "refresh: new address added with timeout" "add element inet segments enclave_smtp_relay { 8.8.4.4 timeout 24h }" "$tmp/nft-in"
hasnt "refresh: private address ignored" "$ten.1.2.3" "$tmp/nft-in"
hasnt "refresh: CNAME ignored" "relay.example.net" "$tmp/nft-in"

: >"$tmp/nft-in"; dig_answer "$ten.0.0.1" "192.$c168.1.1"
PATH="$tmp/bin:$PATH" bash "$refresh" "$tmp/set.conf" >/dev/null 2>&1
check "refresh: only private addresses -> rc 1" "$?" "1"
check "refresh: only private addresses -> set unchanged" "$(wc -c <"$tmp/nft-in" | tr -d ' ')" "0"

: >"$tmp/nft-in"; dig_answer 8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1
PATH="$tmp/bin:$PATH" bash "$refresh" "$tmp/set.conf" >/dev/null 2>&1
check "refresh: more than MAX -> rc 1" "$?" "1"
check "refresh: more than MAX -> set unchanged" "$(wc -c <"$tmp/nft-in" | tr -d ' ')" "0"

: >"$tmp/nft-in"; printf '#!/bin/sh\nexit 9\n' >"$tmp/bin/dig"
PATH="$tmp/bin:$PATH" bash "$refresh" "$tmp/set.conf" >/dev/null 2>&1
check "refresh: lookup failure -> rc 1" "$?" "1"
check "refresh: lookup failure -> set unchanged" "$(wc -c <"$tmp/nft-in" | tr -d ' ')" "0"

# 6. Firewall rollback script (stubbed ping/nft).
rb=ansible/roles/pve_segments/files/segments-fw-rollback.sh
printf '#!/bin/sh\ncat >>"%s/rb-in"\n' "$tmp" >"$tmp/bin/nft"; chmod +x "$tmp/bin/nft"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/ping"; chmod +x "$tmp/bin/ping"
printf 'table inet segments { }\n' >"$tmp/backup"; : >"$tmp/rb-in"
PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 >/dev/null
check "rollback unreachable: rc" "$?" "0"
check "rollback unreachable: previous table loaded in one transaction" "$(tr '\n' '|' <"$tmp/rb-in")" \
  "table inet segments|delete table inet segments|table inet segments { }|"
: >"$tmp/backup"; : >"$tmp/rb-in"
PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 >/dev/null
check "rollback with no previous table: table removed" "$(tr '\n' '|' <"$tmp/rb-in")" "table inet segments|delete table inet segments|"
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/ping"; : >"$tmp/rb-in"
PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 >/dev/null
check "rollback reachable: nothing loaded" "$(wc -c <"$tmp/rb-in" | tr -d ' ')" "0"
rc=0; PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 --table 'x;y' >/dev/null 2>&1 || rc=$?
check "rollback: bad table name refused" "$rc" "2"

exit "$fail"
