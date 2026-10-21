#!/usr/bin/env bash
# Service gateway (role caddy + pihole records), run locally with a fixture site dict:
# site.services -> Caddy routes (Caddyfile) and Pi-hole fqdn records at the gateway's home
# address, under the gateway domain (inventory group_vars/all/gateway.yml: the private
# subdomain site.gateway.subdomain of site.domain, or site.domain without one); disabled
# entries get neither; malformed entries fail the run.
# Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }

# run <services-yaml-flow> [<gateway-yaml-flow>] -> renders $tmp/Caddyfile and $tmp/records;
# returns the play's rc
run() {
  local gw=${2:-}
  [ -n "$gw" ] || gw='{subdomain: internal}'
  cat >"$tmp/play.yml" <<PLAY
- name: Gateway test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/inventory/group_vars/all/gateway.yml
    - $PWD/ansible/inventory/group_vars/all/enclave.yml
  vars:
    inventory_hostname: apps
    site:
      domain: example.com
      email: admin@example.com
      admin_sources: [198.51.100.51/32, 192.0.2.31/32]
      admin_vpn_sources: [100.64.0.7/32]
      pve: {ip: 192.0.2.10, uplink_ip: 198.51.100.250, idrac_ip: 192.0.2.123}
      hosts:
        ragnarok: {ip: 192.0.2.119}
        vault: {ip: 192.0.2.120}
        apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}
      dns:
        local_records: [{name: vault, ref: hosts.vault.ip}]
        acme_resolvers: [198.51.100.53, 198.51.100.54]
      services: $1
      gateway: $gw
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
    - name: Compose file
      ansible.builtin.template:
        src: "$PWD/ansible/roles/caddy/templates/docker-compose.yaml.j2"
        dest: "$tmp/compose.yaml"
        mode: "0600"
      vars:
        caddy_image: anvil/caddy:test
    - name: Only Pi-hole's network exists (homepage and vaultwarden have not run)
      ansible.builtin.include_role:
        name: caddy
        tasks_from: networks.yml
      vars:
        caddy_networks_present: [bridge, host, none, caddy_gateway, pihole_dns]
    - name: Compose file with the networks that exist
      ansible.builtin.template:
        src: "$PWD/ansible/roles/caddy/templates/docker-compose.yaml.j2"
        dest: "$tmp/compose-partial.yaml"
        mode: "0600"
      vars:
        caddy_image: anvil/caddy:test
    - name: Routes not checked
      ansible.builtin.copy:
        content: "{{ caddy_routes_unchecked | join(' ') }}\n"
        dest: "$tmp/unchecked"
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
  {name: home, container: homepage, port: 3000, scheme: http},
  {name: pass, container: vaultwarden, port: 80, scheme: http, enabled: false}]'
if [ "$?" -eq 0 ] && [ -s "$tmp/Caddyfile" ]; then ok "good services render"
else bad_ "good services render"; tail -20 "$tmp/log"; exit 1; fi

has   "one wildcard site under the subdomain" "*.internal.example.com {"
has   "DNS-01 through Cloudflare"          "dns cloudflare {env.CLOUDFLARE_API_TOKEN}"
has   "pve route by host"                  "@pve host pve.internal.example.com"
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

has   "propagation check resolvers from site" "resolvers 198.51.100.53 198.51.100.54"

# Published ports: each bound to one of the VM's two addresses, TCP only, 80 and 443.
ports=$(awk '/^    ports:/{on=1; next} on && /^      - /{print; next} on{on=0}' "$tmp/compose.yaml" | sed -E 's/^ *- *"?//; s/"$//')
if [ "$(printf '%s\n' "$ports" | sort)" = "$(printf '%s\n' 192.0.2.121:443:443/tcp 192.0.2.121:80:80/tcp 198.51.100.249:443:443/tcp 198.51.100.249:80:80/tcp | sort)" ]
then ok "ports: only the lab and home addresses, 80 and 443, TCP"
else bad_ "ports"; printf '%s\n' "$ports"; fi
if printf '%s\n' "$ports" | grep -qvE '^(192\.0\.2\.121|198\.51\.100\.249):(80|443):(80|443)/tcp$'; then bad_ "ports: no unbound, 0.0.0.0 or UDP entry"
else ok "ports: no unbound, 0.0.0.0 or UDP entry"; fi

# Networks: all three by default; only the existing ones when some are missing, and the
# routes to containers on a missing network are not checked.
# Service networks are a mapping (gateway carries gw_priority): the 6-space keys under it.
nets() { awk '/^    networks:/{on=1; next} on && /^      [a-z_]+:/{sub(":","",$1); print $1; next} on && /^        /{next} on && /^      #/{next} on{on=0}' "$1" | tr '\n' ' '; }
if [ "$(nets "$tmp/compose.yaml")" = "gateway pihole_dns homepage_web vaultwarden_web " ]; then ok "networks: all container networks by default"
else bad_ "networks default: $(nets "$tmp/compose.yaml")"; fi
if [ "$(nets "$tmp/compose-partial.yaml")" = "gateway pihole_dns " ] && ! grep -q "homepage_web" "$tmp/compose-partial.yaml"
then ok "networks: a missing network is left out"; else bad_ "networks partial: $(nets "$tmp/compose-partial.yaml")"; fi
if grep -q "@vault_denied not remote_ip 100.64.0.7/32 198.51.100.51/32 192.0.2.31/32" "$tmp/Caddyfile" \
   && grep -q "respond @vault_denied 403" "$tmp/Caddyfile"; then ok "vault: the operator's devices only (403 for others)"
else bad_ "vault: admin-only matcher"; fi
if [ "$(grep -c "_denied not remote_ip" "$tmp/Caddyfile")" = 1 ]; then ok "other routes stay open to the LAN"
else bad_ "admin-only matchers: $(grep -c "_denied not remote_ip" "$tmp/Caddyfile")"; fi
if grep -A1 "^      gateway:" "$tmp/compose.yaml" | grep -q "gw_priority: 100"; then ok "networks: Caddy's own network carries its default route"
else bad_ "networks: gw_priority on gateway"; fi
if [ "$(cat "$tmp/unchecked")" = "home" ]; then ok "routes to a container on a missing network are not checked"
else bad_ "unchecked routes: $(cat "$tmp/unchecked")"; fi

if [ "$(cat "$tmp/records" 2>/dev/null)" = "192.0.2.120 vault.lan.example.com
198.51.100.249 pve.internal.example.com
198.51.100.249 vault.internal.example.com
198.51.100.249 qbit.internal.example.com
198.51.100.249 tv.internal.example.com
198.51.100.249 dns.internal.example.com
198.51.100.249 home.internal.example.com" ]; then ok "records: every enabled name at the gateway's home address, local records kept"
else bad_ "records"; cat "$tmp/records" 2>/dev/null; fi

# No subdomain (empty or absent): the names sit directly under site.domain.
for g in '{subdomain: ""}' '{}'; do
  run '[{name: pve, host: pve.ip, port: 8006, scheme: https, insecure_upstream: true}]' "$g"
  if [ "$?" -eq 0 ] && grep -qF '*.example.com {' "$tmp/Caddyfile" && grep -qF '@pve host pve.example.com' "$tmp/Caddyfile" \
     && grep -qx '198.51.100.249 pve.example.com' "$tmp/records"; then ok "no subdomain ($g): names under the domain"
  else bad_ "no subdomain ($g)"; fi
done

reject() {
  run "$2" "${3:-}"; rc=$?
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
reject "bad subdomain"          '[{name: a, host: pve.ip, port: 1, scheme: http}]' '{subdomain: "In ternal"}'

[ "$fail" -eq 0 ] && echo "PASS: gateway routes and records"
exit "$fail"
