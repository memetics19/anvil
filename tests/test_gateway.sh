#!/usr/bin/env bash
# Service gateway (role caddy + pihole records), run locally with a fixture site dict:
# site.services -> Caddy routes (Caddyfile) and Pi-hole fqdn records at the gateway's home
# address; disabled entries get neither; malformed entries fail the run.
# Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }

# run <services-yaml-flow> -> renders $tmp/Caddyfile and $tmp/records; returns the play's rc
run() {
  cat >"$tmp/play.yml" <<PLAY
- name: Gateway test
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: apps
    site:
      domain: example.com
      email: admin@example.com
      pve: {ip: 192.0.2.10, uplink_ip: 198.51.100.250, idrac_ip: 192.0.2.123}
      hosts:
        ragnarok: {ip: 192.0.2.119}
        vault: {ip: 192.0.2.120}
        apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}
      dns:
        local_records: [{name: vault, ref: hosts.vault.ip}]
      services: $1
    caddy_upstream_cas: {vault: /nonexistent/vault-ca.pem}
  tasks:
    - name: Routes
      ansible.builtin.include_role:
        name: caddy
        tasks_from: services.yml
        public: true
    - name: Caddyfile
      ansible.builtin.template:
        src: "$PWD/ansible/roles/caddy/templates/Caddyfile.j2"
        dest: "$tmp/Caddyfile"
        mode: "0600"
    - name: Records
      ansible.builtin.include_role:
        name: pihole
        tasks_from: records.yml
    - name: Write them out
      ansible.builtin.copy:
        content: "{{ pihole_hosts | join('\n') }}\n"
        dest: "$tmp/records"
        mode: "0600"
PLAY
  rm -f "$tmp/Caddyfile" "$tmp/records"
  ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1
}

has() { if grep -qF -- "$2" "$tmp/Caddyfile" 2>/dev/null; then ok "$1"; else bad_ "$1 (missing: $2)"; fi; }
hasnt() { if grep -qF -- "$2" "$tmp/Caddyfile" 2>/dev/null; then bad_ "$1 (found: $2)"; else ok "$1"; fi; }
# block <name>: the handle block of one route
block() { awk -v n="handle @$1 {" '$0 ~ n {on=1} on {print} on && /^\t}$/ {exit}' "$tmp/Caddyfile"; }

run '[
  {name: pve, host: pve.ip, port: 8006, scheme: https, insecure_upstream: true, websocket: true},
  {name: vault, host: hosts.vault.ip, port: 8200, scheme: https, upstream_ca: vault},
  {name: qbit, host: hosts.ragnarok.ip, port: 8080, scheme: http, host_header: upstream},
  {name: tv, host: hosts.ragnarok.ip, port: 34401, scheme: http, stream: true},
  {name: dns, container: pihole, port: 80, scheme: http, home: /admin/},
  {name: pass, container: vaultwarden, port: 80, scheme: http, enabled: false}]'
if [ "$?" -eq 0 ] && [ -s "$tmp/Caddyfile" ]; then ok "good services render"
else bad_ "good services render"; tail -20 "$tmp/log"; exit 1; fi

has   "one wildcard site"                  "*.example.com {"
has   "DNS-01 through Cloudflare"          "dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
has   "pve route by host"                  "@pve host pve.example.com"
has   "pve upstream from the site dict"    "reverse_proxy https://192.0.2.10:8006 {"
block pve | grep -q tls_insecure_skip_verify && ok "pve: self-signed upstream" || bad_ "pve: self-signed upstream"
block pve | grep -q 'stream_close_delay' && ok "pve: websockets survive reloads" || bad_ "pve: websocket"
block vault | grep -q 'tls_trust_pool file /etc/caddy/ca/vault.pem' && ok "vault: own CA" || bad_ "vault: own CA"
block vault | grep -q tls_insecure_skip_verify && bad_ "vault: verifies its certificate" || ok "vault: verifies its certificate"
block qbit | grep -q 'header_up Host {upstream_hostport}' && ok "qbit: Host = upstream" || bad_ "qbit: Host header"
block pve | grep -q 'header_up Host' && bad_ "pve: original Host" || ok "pve: original Host"
block tv | grep -q 'flush_interval -1' && ok "tv: streamed" || bad_ "tv: streamed"
block tv | grep -q 'response_header_timeout' && bad_ "tv: no response timeout" || ok "tv: no response timeout"
block dns | grep -q 'reverse_proxy http://pihole:80 {' && ok "dns: container upstream" || bad_ "dns: container upstream"
block dns | grep -q 'redir / /admin/' && ok "dns: / redirects to /admin/" || bad_ "dns: home redirect"
hasnt "disabled entry has no route"        "@pass"
has   "unknown names are refused"          "abort"
hasnt "no HTTP/3 (only TCP is published)"  "h3"

if [ "$(cat "$tmp/records" 2>/dev/null)" = "192.0.2.120 vault.lan.example.com
198.51.100.249 pve.example.com
198.51.100.249 vault.example.com
198.51.100.249 qbit.example.com
198.51.100.249 tv.example.com
198.51.100.249 dns.example.com" ]; then ok "records: every enabled name at the gateway's home address, local records kept"
else bad_ "records"; cat "$tmp/records" 2>/dev/null; fi

reject() {
  run "$2"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'site.services' "$tmp/log"; then ok "rejects $1"
  else bad_ "accepts $1 (rc $rc)"; fi
}
reject "upper-case name"        '[{name: Pve, host: pve.ip, port: 1, scheme: http}]'
reject "same name twice"        '[{name: a, host: pve.ip, port: 1, scheme: http}, {name: a, host: pve.ip, port: 2, scheme: http}]'
reject "host to nothing"        '[{name: a, host: hosts.nope.ip, port: 1, scheme: http}]'
reject "host to a non-address"  '[{name: a, host: domain, port: 1, scheme: http}]'
reject "host and container"     '[{name: a, host: pve.ip, container: x, port: 1, scheme: http}]'
reject "no upstream"            '[{name: a, port: 1, scheme: http}]'
reject "port out of range"      '[{name: a, host: pve.ip, port: 70000, scheme: http}]'
reject "unknown scheme"         '[{name: a, host: pve.ip, port: 1, scheme: ftp}]'
reject "insecure on http"       '[{name: a, host: pve.ip, port: 1, scheme: http, insecure_upstream: true}]'
reject "unknown CA"             '[{name: a, host: pve.ip, port: 1, scheme: https, upstream_ca: other}]'
reject "insecure and a CA"      '[{name: a, host: pve.ip, port: 1, scheme: https, upstream_ca: vault, insecure_upstream: true}]'
reject "bad host_header"        '[{name: a, host: pve.ip, port: 1, scheme: http, host_header: other}]'

[ "$fail" -eq 0 ] && echo "PASS: gateway routes and records"
exit "$fail"
