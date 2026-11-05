#!/usr/bin/env bash
# Frigate's metrics for the monitoring VM (role frigate_stack, templates/nginx-default.j2): nginx
# on the lab address answers /api/metrics alone, from the loopback API, only to the monitoring
# VM and the admin sources. Every other path gets 404, and port 5000 stays on loopback. With no
# source to allow, there is no listener. Renders locally with documentation addresses.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/frigate_stack

cat >"$tmp/play.yml" <<PLAY
- name: Render Frigate's nginx site
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    inventory_hostname: frigate
  tasks:
    - ansible.builtin.template: {src: "$r/templates/nginx-default.j2", dest: "$tmp/with.conf", mode: "0600"}
      vars:
        site: {domain: example.com, admin_sources: [192.0.2.30/32], admin_vpn_sources: [100.64.0.7/32],
               hosts: {frigate: {ip: 192.0.2.114}, monitoring: {ip: 192.0.2.132}}}
    - ansible.builtin.template: {src: "$r/templates/nginx-default.j2", dest: "$tmp/without.conf", mode: "0600"}
      vars:
        site: {domain: example.com, hosts: {frigate: {ip: 192.0.2.114}}}
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "the site renders"; else bad_ "the site renders"; cat "$tmp/render.log"; exit 1; fi
m=$tmp/metrics.conf
sed -n '/listen 192.0.2.114:9711;/,/^}/p' "$tmp/with.conf" >"$m"

check "the listener is on the lab address, port 9711" "[ -s $m ]"
check "it lets in the monitoring VM and the admin sources" \
  "grep -qx '    allow 192.0.2.132;' $m && grep -qx '    allow 192.0.2.30/32;' $m && grep -qx '    allow 100.64.0.7/32;' $m"
check "everyone else is refused" "grep -qx '    deny all;' $m"
check "only /api/metrics goes to the loopback API" \
  "[ \"\$(grep -c proxy_pass $m)\" = 1 ] && grep -A1 'location = /api/metrics' $m | grep -q 'proxy_pass http://127.0.0.1:5000/api/metrics;'"
check "every other path gets 404" "grep -A1 'location / {' $m | grep -q 'return 404;'"
check "with no source to allow, no listener" "! grep -q ':9711' $tmp/without.conf"
check "port 5000 is published on loopback only" \
  "grep -q '127.0.0.1:5000:5000' $r/templates/docker-compose.yml.j2 && ! grep ':5000:5000' $r/templates/docker-compose.yml.j2 | grep -vq '127.0.0.1:5000:5000'"

[ "$fail" = 0 ] && echo "PASS: frigate metrics"
exit "$fail"
