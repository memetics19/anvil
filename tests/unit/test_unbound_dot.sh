#!/usr/bin/env bash
# Unbound's DNS over TLS upstreams (role pihole, templates/unbound.conf.j2): with the default
# list every query is forwarded over TLS to Quad9 and Cloudflare, checked against their
# certificate names, with no plain DNS fallback. With an empty list there is no forward zone
# and Unbound resolves recursively as before. Renders locally.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# render <extra vars as YAML flow> <out file>
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: Unbound settings
  hosts: localhost
  gather_facts: false
  vars:
    site: {hosts: {localhost: {ip: 192.0.2.10, home_ip: 192.0.2.11, dns_subnet: 198.51.100.0/29, dns_unbound_ip: 198.51.100.2}}}
    inventory_hostname: localhost
  vars_files:
    - $PWD/ansible/roles/pihole/defaults/main.yml
  tasks:
    - ansible.builtin.set_fact: $1
    - ansible.builtin.template:
        src: $PWD/ansible/roles/pihole/templates/unbound.conf.j2
        dest: $2
        mode: "0644"
PLAY
  ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1
}

if render '{pihole_test_default: true}' "$tmp/dot.conf"; then ok "default renders"; else bad_ "default renders"; cat "$tmp/log"; exit 1; fi
c=$tmp/dot.conf
check "one forward zone for everything, over TLS" "grep -qx 'forward-zone:' '$c' && grep -qx '    name: \".\"' '$c' && grep -qx '    forward-tls-upstream: yes' '$c'"
check "Quad9 and Cloudflare on 853, each with its certificate name" \
  "[ \"\$(grep -c 'forward-addr: ' '$c')\" = 4 ] && grep -qx '    forward-addr: 9.9.9.9@853#dns.quad9.net' '$c' && grep -qx '    forward-addr: 1.1.1.1@853#cloudflare-dns.com' '$c'"
check "every upstream is on 853 with a name" "! grep 'forward-addr: ' '$c' | grep -vqE '@853#[a-z0-9.-]+\$'"
check "no plain DNS fallback (no forward-first)" "! grep -q 'forward-first' '$c'"
check "the cache sizes stay" "grep -q 'msg-cache-size: 16m' '$c'"

if render '{pihole_unbound_dot_upstreams: []}' "$tmp/rec.conf"; then
  check "an empty list keeps Unbound recursive (no forward zone)" "! grep -q 'forward-zone' '$tmp/rec.conf'"
else bad_ "an empty list renders"; fi

[ "$fail" = 0 ] && echo "PASS: unbound DoT"
exit "$fail"
