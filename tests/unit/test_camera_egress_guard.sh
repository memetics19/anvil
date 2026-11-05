#!/usr/bin/env bash
# The camera egress guard (role camera_egress_guard): the cameras, from the site dict, may
# only answer connections opened to them and ask for the time; everything else they send
# through the Proxmox host is dropped and counted. The camera VLAN has no internet either.
# Renders locally, needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/camera_egress_guard

cat >"$tmp/play.yml" <<PLAY
- name: Render the guard
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    site:
      frigate_stack:
        camera: {host: 198.51.100.107, port: 554, path: /stream1}
        cameras: [{name: garden, host: 198.51.100.37}, {name: garage, host: 198.51.100.36}]
  tasks:
    - ansible.builtin.template: {src: "$r/templates/camera-egress-guard.nft.j2", dest: "$tmp/guard.nft", mode: "0644"}
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "the guard renders"; else bad_ "the guard renders"; cat "$tmp/render.log"; exit 1; fi
g=$tmp/guard.nft
rules=$(grep -E '^\s+ip saddr @cameras' "$g")

check "every camera from the site dict, the first one too" \
  "grep -q 'elements = { 198.51.100.107, 198.51.100.37, 198.51.100.36 }' '$g'"
check "replies to connections opened to them pass" "grep -q 'ip saddr @cameras ct state established,related counter accept' <<<\"\$rules\""
check "NTP passes" "grep -q 'ip saddr @cameras udp dport 123 counter accept' <<<\"\$rules\""
check "everything else they send is dropped and counted, last" "[ \"\$(tail -1 <<<\"\$rules\" | xargs)\" = 'ip saddr @cameras counter drop' ]"
check "nothing else is touched: every rule is about the cameras" \
  "[ \"\$(grep -cE '^\s+(ip|tcp|udp|ct|meta|counter|drop|accept)' '$g')\" = \"\$(wc -l <<<\"\$rules\" | xargs)\" ]"
check "it runs before the other forward filters" "grep -q 'type filter hook forward priority filter - 2; policy accept;' '$g'"
if command -v nft >/dev/null && sudo -n true 2>/dev/null; then
  check "nft accepts it" "sudo -n nft -c -f '$g'"
fi
check "loaded at boot, before the network" "grep -q '^Before=network-pre.target' $r/templates/camera-egress-guard.service.j2"
check "on the Proxmox host" "grep -A3 '^- name: Camera egress guard' ansible/playbooks/host.yml | grep -q 'hosts: proxmox'"
check "the camera VLAN has no internet" "grep -qx 'cameras_internet: false' ansible/inventory/group_vars/proxmox.yml"

[ "$fail" = 0 ] && echo "PASS: camera egress guard"
exit "$fail"
