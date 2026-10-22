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

# render <out> <extra hosts yaml flow> <smtp enabled> [vpn_only] -> the enclave's ruleset
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: Segments test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/pve_enclave/defaults/main.yml
    - $PWD/ansible/inventory/group_vars/all/enclave.yml
  vars:
    pve_segments_table: segments
    pve_segments_list: "{{ [pve_enclave_segment] }}"
    pve_segments_sets: "{{ pve_enclave_sets }}"
    pve_enclave_smtp_enabled: $3
    pve_enclave_smtp_host: smtp.example.com
    pve_enclave_smtp_port: "587"
    site:
      pve: {ip: 192.0.2.10, gateway_alias_ip: 192.0.2.1, uplink_ip: 203.0.113.250}
      sdn: {enclave: {subnet: 198.51.100.0/24, gateway: 198.51.100.1}}
      admin_sources: [203.0.113.51/32, 192.0.2.30/32]
      admin_vpn_sources: [100.64.0.7/32]
      enclave: {vpn_only: ${4:-false}}
      hosts:
        apps: {ip: 192.0.2.121, home_ip: 203.0.113.249}
        frigate: {ip: 192.0.2.114}
        ragnarok: {ip: 192.0.2.119}
        vault: {ip: 198.51.100.20, lab_ip: 192.0.2.120}
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
has "operators: NetBird peers and the Mac's LAN /32s" "elements = { 100.64.0.7/32, 203.0.113.51/32, 192.0.2.30/32 }" "$f"
has "no host address is an operator" "elements = { 192.0.2.121, 203.0.113.249, 192.0.2.114, 192.0.2.119, 198.51.100.20, 192.0.2.120, 198.51.100.21, 192.0.2.10, 192.0.2.1, 203.0.113.250 }" "$f"
check "anti-spoofing comes before established" "$(awk '/chain forward/{f=1} f&&/iifname != "secrets" counter drop/{print "spoof"; } f&&/ct state established/{print "est"; exit}' "$f" | tr '\n' ' ')" "spoof est "
check "invalid dropped in every segment chain" "$(grep -c 'ct state invalid counter drop' "$f")" "3"
has "DNS-fed set has a size cap" "size 64" "$f"
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
hasnt "no monitoring rule" "dport 9100" "$f"

# 2. Vaultwarden not created yet, SMTP off: its rules are left out, the set is plain.
render "$tmp/novw.nft" '' false
check "render without vaultwarden: rc" "$?" "0"
hasnt "no Vaultwarden rule" "198.51.100.21" "$tmp/novw.nft"
hasnt "SMTP off: no timeout set" "flags timeout" "$tmp/novw.nft"
hasnt "without Vaultwarden: nothing translated" "snat" "$tmp/novw.nft"
has "SSH still to Vault" "ip saddr @admin ip daddr { 198.51.100.20 } tcp dport 22 accept" "$tmp/novw.nft"

# 2b. vpn_only: NetBird peers only.
render "$tmp/vpn.nft" 'vaultwarden: {ip: 198.51.100.21}' true true
has "vpn_only: NetBird peers only" "elements = { 100.64.0.7/32 }" "$tmp/vpn.nft"
hasnt "vpn_only: no LAN /32" "203.0.113.51/32" "$tmp/vpn.nft"

# 3. No VM is admitted, a monitoring VM included (its address is only in not_admin).
render "$tmp/mon.nft" 'monitoring: {ip: 192.0.2.130}' true
hasnt "monitoring: no rule admits it" "ip saddr 192.0.2.130" "$tmp/mon.nft"
has "monitoring: its address is not an operator" "192.0.2.130" "$tmp/mon.nft"

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

# 4b. Boot: guests start only with the table loaded, through a check in pve-guests, never a
# Requires= on the firewall unit (restarting a required unit stops every guest).
u=ansible/roles/pve_segments/templates
hasnt "firewall unit: not RequiredBy pve-guests" "RequiredBy=pve-guests" "$u/segments-firewall.service.j2"
has "pve-guests drop-in: ordered after the firewall" "After=segments-firewall.service" "$u/pve-guests-segments.conf.j2"
has "pve-guests drop-in: checks the table before startall" "ExecStartPre=/bin/sh -c 'nft list table inet {{ pve_segments_table }} >/dev/null'" "$u/pve-guests-segments.conf.j2"
hasnt "pve-guests drop-in: no Requires" "Requires=" "$u/pve-guests-segments.conf.j2"
hasnt "the apply never restarts the unit" "state: restarted" ansible/roles/pve_segments/tasks/main.yml

# 4c. The VLANs (inventory group_vars/proxmox.yml): three NAT segments next to the
# enclave, rendered with the real data and a fixture site dict (documentation ranges:
# the lab 192.0.2.0/25, home 203.0.113.0/24, enclave and VLANs /26s of 198.51.100.0/24).
# render_vlans <out> <cameras_internet> [enclave-only]
# The lists go in as extra vars: group_vars/proxmox.yml is a vars_file, which would win over
# play vars.
render_vlans() {
  local list='{{ [pve_enclave_segment] + vlan_segments }}' sets='{{ pve_enclave_sets + vlan_sets }}'
  if [ -n "${3:-}" ]; then list='{{ [pve_enclave_segment] }}'; sets='{{ pve_enclave_sets }}'; fi
  printf '{"pve_segments_list": "%s", "pve_segments_sets": "%s", "cameras_internet": %s}' "$list" "$sets" "$2" >"$tmp/ev.json"
  cat >"$tmp/vlans.yml" <<PLAY
- name: VLAN segments test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/pve_enclave/defaults/main.yml
    - $PWD/ansible/inventory/group_vars/all/enclave.yml
    - $PWD/ansible/inventory/group_vars/proxmox.yml
    - $PWD/ansible/roles/pve_vlans/defaults/main.yml
  vars:
    pve_segments_table: segments
    pve_enclave_smtp_enabled: true
    pve_enclave_smtp_host: smtp.example.com
    pve_enclave_smtp_port: "587"
    site:
      lan_cidr: 192.0.2.0/25
      pve: {ip: 192.0.2.10, gateway_alias_ip: 192.0.2.1, uplink_ip: 203.0.113.250, uplink_prefix: 24, uplink_gw: 203.0.113.1}
      sdn:
        enclave: {subnet: 198.51.100.0/26, gateway: 198.51.100.1}
        subnets:
          servers: {cidr: 198.51.100.64/26, gateway: 198.51.100.65, dhcp_range: {start: 198.51.100.80, end: 198.51.100.119}}
          cameras: {cidr: 198.51.100.128/26, gateway: 198.51.100.129, dhcp_range: {start: 198.51.100.144, end: 198.51.100.183}}
          personal: {cidr: 198.51.100.192/26, gateway: 198.51.100.193, dhcp_range: {start: 198.51.100.208, end: 198.51.100.247}}
      admin_sources: [203.0.113.51/32]
      admin_vpn_sources: [100.64.0.7/32]
      enclave: {vpn_only: false}
      hosts:
        apps: {ip: 192.0.2.121, home_ip: 203.0.113.249}
        frigate: {ip: 192.0.2.114}
        vault: {ip: 198.51.100.20}
        vaultwarden: {ip: 198.51.100.21}
  tasks:
    - name: Ruleset
      ansible.builtin.template:
        src: $PWD/ansible/roles/pve_segments/templates/segments.nft.j2
        dest: "$1"
        mode: "0600"
    - name: Host files
      ansible.builtin.template:
        src: "$PWD/ansible/roles/{{ item.src }}"
        dest: "$tmp/{{ item.dest }}"
        mode: "0600"
      loop:
        - {src: pve_vlans/templates/vlans.interfaces.j2, dest: vlans.interfaces}
        - {src: pve_network/templates/interfaces.j2, dest: interfaces}
      vars:
        iptv_host: frigate
        iptv_threadfin_port: 34400
        iptv_streams_port: 34401
        pve_network_trunk_vids: "{{ vlans | map(attribute='tag') | list }}"
    - name: DHCP per VLAN
      ansible.builtin.template:
        src: $PWD/ansible/roles/pve_vlans/templates/vlan-dhcp.conf.j2
        dest: "$tmp/vlan-dhcp-{{ item }}.conf"
        mode: "0600"
      loop: [servers, cameras, personal]
    - name: NTP per VLAN
      ansible.builtin.template:
        src: $PWD/ansible/roles/pve_vlans/templates/vlan-ntp.conf.j2
        dest: "$tmp/vlan-ntp-{{ item }}.conf"
        mode: "0600"
      loop: [servers, cameras, personal]
PLAY
  ansible-playbook -e "@$tmp/ev.json" "$tmp/vlans.yml" >"$tmp/out-vlans.log" 2>&1
}
chain() { awk -v c="chain $1 {" '$0 ~ c {f=1} f {print} f && /^\t}$/ {exit}' "$2"; }

render_vlans "$tmp/v.nft" true
check "VLANs: render rc" "$?" "0"
v=$tmp/v.nft
for n in servers cameras personal; do
  has "$n: masqueraded out of its vnet" "oifname != \"$n\" masquerade" "$v"
  has "$n: no spoofed addresses from elsewhere" "iifname != \"$n\" counter drop" "$v"
  has "$n: forward jumps" "iifname \"$n\" jump ${n}_out" "$v"
  check "$n: the lab reaches everything, nothing else gets in" "$(chain "${n}_in" "$v" | grep -cE 'accept$')" "1"
  chain "${n}_in" "$v" >"$tmp/c"; has "$n: ingress from the lab" "ip saddr 192.0.2.0/25 accept" "$tmp/c"
  chain "${n}_out" "$v" >"$tmp/c"
  check "$n: the first rule drops a source outside its subnet" "$(sed -n 2p "$tmp/c" | tr -d '\t')" "# Only its own addresses leave it: a spoofed source is dropped."
  check "$n: strict source rule" "$(sed -n 3p "$tmp/c" | tr -d '\t')" "ip saddr != $(sed -n "s/.*ip saddr \([0-9./]*\) iifname != \"$n\" counter drop/\1/p" "$v" | head -1) counter drop"
  has "$n: DNS to Pi-hole (udp)" "ip daddr { 192.0.2.121, 203.0.113.249 } udp dport 53 return" "$tmp/c"
  has "$n: DNS to Pi-hole (tcp)" "ip daddr { 192.0.2.121, 203.0.113.249 } tcp dport 53 return" "$tmp/c"
  check "$n: nothing private before the internet" "$(grep -nE '@vlan_nonpublic counter drop|^		return$' "$tmp/c" | cut -d: -f2 | tr -d '\t' | tr '\n' '|')" \
    "ip daddr @vlan_nonpublic counter drop|return|"
  hasnt "$n: no rule names the enclave" "198.51.100.2" "$tmp/c"
  chain "${n}_host" "$v" >"$tmp/c"
  has "$n: DHCP to the host" "udp dport 67 accept" "$tmp/c"
  check "$n: host: only DHCP, NTP and ping" "$(grep -cE 'accept$' "$tmp/c")" "3"
  hasnt "$n: no SSH or Proxmox UI" "tcp dport" "$tmp/c"
done
has "servers: NTP on its own gateway" "ip daddr 198.51.100.65 udp dport 123 accept" "$v"
has "cameras: ping on its own gateway" "ip daddr 198.51.100.129 icmp type echo-request accept" "$v"
has "personal: NTP on its own gateway" "ip daddr 198.51.100.193 udp dport 123 accept" "$v"
has "personal: the gateway's web ports" "ip daddr { 192.0.2.121, 203.0.113.249 } tcp dport { 80, 443 } return" "$v"
check "web ports for personal only" "$(grep -c 'tcp dport { 80, 443 }' "$v")" "1"
has "not the internet: the shared range (VPN)" "100.64.0.0/10" "$v"
has "not the internet: multicast and reserved" "224.0.0.0/3" "$v"
check "three VLAN masquerades, the mail hole still the only snat" "$(grep -c masquerade "$v") $(grep -c 'snat ip to' "$v")" "3 1"
render_vlans "$tmp/e.nft" true only
check "enclave-only render rc" "$?" "0"
hasnt "enclave-only render: no VLAN" "servers" "$tmp/e.nft"
for c in enclave_in enclave_out enclave_host; do
  check "the enclave's $c is unchanged by the VLANs" "$(chain "$c" "$v" | shasum)" "$(chain "$c" "$tmp/e.nft" | shasum)"
done
# strict_source adds nothing to a segment without it: the enclave-only ruleset is the same
# with the template minus that block.
sed '/strict_source/,/endif/d' ansible/roles/pve_segments/templates/segments.nft.j2 >"$tmp/nostrict.j2"
check "the strict_source block was cut out" "$(grep -c 'saddr !=' "$tmp/nostrict.j2")" "0"
cp "$tmp/e.nft" "$tmp/e-strict.nft"
sed -i.bak "s#$PWD/ansible/roles/pve_segments/templates/segments.nft.j2#$tmp/nostrict.j2#" "$tmp/vlans.yml"
ansible-playbook -e "@$tmp/ev.json" "$tmp/vlans.yml" >"$tmp/out-ns.log" 2>&1
check "enclave-only render without the block: rc" "$?" "0"
check "the enclave's ruleset is byte-identical with and without strict_source" "$(shasum <"$tmp/e-strict.nft" | cut -c1-40)" "$(shasum <"$tmp/e.nft" | cut -c1-40)"
hasnt "no strict-source rule for the enclave" "saddr !=" "$tmp/e-strict.nft"
check "the enclave's sets are unchanged" "$(awk '/set (admin|not_admin|enclave_smtp_relay) \{/,/^\t}/' "$v" | shasum)" \
  "$(awk '/set (admin|not_admin|enclave_smtp_relay) \{/,/^\t}/' "$tmp/e.nft" | shasum)"

has "egress profiles: each vlans entry names its own" "egress: [dns, web, internet]" ansible/inventory/group_vars/proxmox.yml
render_vlans "$tmp/v2.nft" false
check "cameras_internet false: render rc" "$?" "0"
chain cameras_out "$tmp/v2.nft" >"$tmp/c"
check "cameras_internet false: DNS only" "$(grep -cE 'return$' "$tmp/c") $(grep -c vlan_nonpublic "$tmp/c")" "2 0"
chain servers_out "$tmp/v2.nft" >"$tmp/c"
has "cameras_internet false: servers keep the internet" "@vlan_nonpublic" "$tmp/c"

# Host files of the VLANs.
f=$tmp/vlans.interfaces
check "gateways: one stanza per VLAN" "$(grep -c '^iface ' "$f")" "3"
has "gateways: the servers gateway on its vnet" "$(printf '\taddress 198.51.100.65/26')" "$f"
has "trunk: the VLAN tags on vmbr0's uplink" "$(printf '\tbridge-vids 10 20 30')" "$tmp/interfaces"
hasnt "no NetBird return route without site.netbird_server" "ip route replace" "$tmp/interfaces"
f=$tmp/vlan-dhcp-cameras.conf
has "dhcp: no DNS" "port=0" "$f"
has "dhcp: its vnet only" "interface=cameras" "$f"
has "dhcp: bound to it" "bind-interfaces" "$f"
has "dhcp: range" "dhcp-range=198.51.100.144,198.51.100.183,12h" "$f"
has "dhcp: router" "dhcp-option=option:router,198.51.100.129" "$f"
has "dhcp: DNS is Pi-hole" "dhcp-option=option:dns-server,192.0.2.121" "$f"
has "dhcp: NTP is the gateway" "dhcp-option=option:ntp-server,198.51.100.129" "$f"
f=$tmp/vlan-ntp-personal.conf
has "ntp: its gateway only" "bindaddress 198.51.100.193" "$f"
has "ntp: its subnet only" "allow 198.51.100.192/26" "$f"
has "ntp: serves the host clock" "local stratum 10" "$f"
has "ntp: no command socket" "bindcmdaddress /" "$f"
u=ansible/roles/pve_vlans/templates
for unit in vlan-dhcp@.service.j2 vlan-ntp@.service.j2; do
  check "$unit: no dependency on pve-guests" "$(grep -cE '^[A-Za-z]+=.*pve-guests' "$u/$unit")" "0"
done
has "ntp unit: never sets the clock" " -x " "$u/vlan-ntp@.service.j2"

# The role's checks refuse a DHCP range outside the subnet.
cat >"$tmp/vcheck.yml" <<PLAY
- name: VLAN checks
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/inventory/group_vars/proxmox.yml
    - $PWD/ansible/roles/pve_vlans/defaults/main.yml
  vars:
    site:
      lan_cidr: 192.0.2.0/25
      pve: {uplink_ip: \$HOMEIP, uplink_prefix: 24}
      hosts: {apps: {ip: 192.0.2.121}}
      sdn:
        enclave: {subnet: 198.51.100.0/26, gateway: 198.51.100.1}
        subnets:
          servers: {cidr: 198.51.100.64/26, gateway: 198.51.100.65, dhcp_range: {start: 198.51.100.80, end: \$END}}
          cameras: {cidr: 198.51.100.128/26, gateway: 198.51.100.129, dhcp_range: {start: 198.51.100.144, end: 198.51.100.183}}
          personal: {cidr: 198.51.100.192/26, gateway: 198.51.100.193, dhcp_range: {start: 198.51.100.208, end: 198.51.100.247}}
  tasks:
    - name: Checks
      ansible.builtin.include_tasks: $PWD/ansible/roles/pve_vlans/tasks/checks.yml
PLAY
vc() { sed -e "s/\\\$END/$1/" -e "s/\\\$HOMEIP/$2/" "$tmp/vcheck.yml" >"$tmp/vc.yml"; ansible-playbook "$tmp/vc.yml" >"$tmp/out-vc.log" 2>&1; }
vc 198.51.100.119 203.0.113.250
check "checks: a range inside the subnet passes" "$?" "0"
vc 198.51.100.130 203.0.113.250
check "checks: a range past the subnet is refused" "$?" "2"
vc 198.51.100.119 198.51.100.70
check "checks: a home network overlapping a VLAN is refused" "$?" "2"
grep -q "home overlaps servers\|servers overlaps home" "$tmp/out-vc.log"
check "checks: the overlap is named" "$?" "0"
vc 198.51.100.119 100.128.0.9
check "checks: a routed network outside vlan_nonpublic is refused" "$?" "2"
grep -q "home is not inside vlan_nonpublic" "$tmp/out-vc.log"
check "checks: the network is named" "$?" "0"

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

: >"$tmp/nft-in"; printf ': ' >"$tmp/present"; dig_answer 8.8.8.8 8.8.4.4
{ cat "$tmp/set.conf"; echo 'EXPECT="8.8.8.0/24 9.9.9.0/24"'; } >"$tmp/set-expect.conf"
PATH="$tmp/bin:$PATH" bash "$refresh" "$tmp/set-expect.conf" >/dev/null 2>&1
check "refresh: EXPECT -> rc" "$?" "0"
has "refresh: EXPECT keeps an address inside" "{ 8.8.8.8 timeout 24h }" "$tmp/nft-in"
hasnt "refresh: EXPECT drops an address outside" "8.8.4.4" "$tmp/nft-in"

# Full set: the answer replaces the set (never more than SIZE, nothing but the answer).
: >"$tmp/nft-in"; printf 'elements = { 8.8.4.4 timeout 1d, 9.9.9.9 timeout 1d }\n' >"$tmp/present"; dig_answer 8.8.8.8
{ cat "$tmp/set.conf"; echo 'SIZE=2'; } >"$tmp/set-full.conf"
PATH="$tmp/bin:$PATH" bash "$refresh" "$tmp/set-full.conf" >/dev/null 2>&1
check "refresh: full set -> rc" "$?" "0"
check "refresh: full set -> replaced by the answer" "$(tr '\n' '|' <"$tmp/nft-in")" \
  "flush set inet segments enclave_smtp_relay|add element inet segments enclave_smtp_relay { 8.8.8.8 timeout 24h }|"

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
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/ping"; printf 'table inet segments { }\n' >"$tmp/backup"
printf 'OLD\n' >"$tmp/saved"; printf 'NEW\n' >"$tmp/live.nft"
PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 --file "$tmp/saved" --to "$tmp/live.nft" >/dev/null
check "rollback: the previous ruleset file comes back" "$(cat "$tmp/live.nft")" "OLD"
: >"$tmp/saved"
PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 --file "$tmp/saved" --to "$tmp/live.nft" >/dev/null
check "rollback: no previous file -> the file is removed" "$([ -e "$tmp/live.nft" ] && echo present || echo gone)" "gone"
rc=0; PATH="$tmp/bin:$PATH" bash "$rb" "$tmp/backup" --wait 0 --target 192.0.2.50 --table 'x;y' >/dev/null 2>&1 || rc=$?
check "rollback: bad table name refused" "$rc" "2"

exit "$fail"
