#!/usr/bin/env bash
# Self-hosted NetBird (roles netbird_server and netbird_peer, Task 13c), run locally with a
# fixture site dict and fake secrets:
# - the server configuration, Caddyfile and compose file: public STUN only, ports on the
#   lab address and loopback only, pinned images, a memory cap on every service, no secret
#   in the compose file;
# - the netbird-home unit: kept apart from the cloud client;
# - the Proxmox host's return route for the network's peer addresses;
# - the API helper against an in-memory API stub: setup, reconcile (and a second run with
#   nothing to do), check mode without writes, the setup key.
# Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
stub_pid=
trap '[ -n "$stub_pid" ] && kill "$stub_pid" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1"; fi; }
hasnt() { if grep -qF -- "$2" "$3"; then bad "$1"; else ok "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: NetBird server test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/inventory/group_vars/all/gateway.yml
    - $PWD/ansible/roles/netbird_server/defaults/main.yml
    - $PWD/ansible/roles/netbird_peer/defaults/main.yml
  vars:
    caddy_image_resolved: anvil/caddy:test
    inventory_hostname: netbird
    site:
      domain: example.com
      email: admin@example.com
      lan_cidr: 192.0.2.0/24
      gateway: {subdomain: internal}
      netbird_domain: sync.example.com
      netbird_server: {network_range: 100.64.0.0/16}
      pve: {ip: 192.0.2.10, gateway_alias_ip: 192.0.2.1, uplink_ip: 198.51.100.250, uplink_prefix: 24, uplink_gw: 198.51.100.1}
      hosts:
        netbird: {ip: 192.0.2.115}
        frigate: {ip: 192.0.2.114}
        apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}
    netbird_server_secrets:
      relay_secret: fake-relay-secret
      datastore_key: FAKEDATASTOREKEY
      idp_session_key: fake-session-key
      owner_password: fake
  tasks:
    - name: Render the files the compose file hashes
      ansible.builtin.set_fact:
        netbird_server_config: "{{ lookup('ansible.builtin.template', '$PWD/ansible/roles/netbird_server/templates/config.yaml.j2') }}"
        netbird_server_caddyfile: "{{ lookup('ansible.builtin.template', '$PWD/ansible/roles/netbird_server/templates/Caddyfile.j2') }}"
    - name: Render
      ansible.builtin.template:
        src: "{{ item.src }}"
        dest: "$tmp/{{ item.dest }}"
        mode: "0600"
      loop:
        - {src: $PWD/ansible/roles/netbird_server/templates/config.yaml.j2, dest: config.yaml}
        - {src: $PWD/ansible/roles/netbird_server/templates/Caddyfile.j2, dest: Caddyfile}
        - {src: $PWD/ansible/roles/netbird_server/templates/docker-compose.yaml.j2, dest: docker-compose.yaml}
        - {src: $PWD/ansible/roles/netbird_peer/templates/netbird-home.service.j2, dest: netbird-home.service}
    - name: The Proxmox host's interfaces
      ansible.builtin.template:
        src: $PWD/ansible/roles/pve_network/templates/interfaces.j2
        dest: "$tmp/interfaces"
        mode: "0600"
      vars:
        iptv_host: frigate
        iptv_threadfin_port: 34400
        iptv_streams_port: 34401
        pve_network_trunk_vids: []
        pve_network_netbird_return_route: true
    - name: The Proxmox host's interfaces without the return route switch
      ansible.builtin.template:
        src: $PWD/ansible/roles/pve_network/templates/interfaces.j2
        dest: "$tmp/interfaces.off"
        mode: "0600"
      vars:
        iptv_host: frigate
        iptv_threadfin_port: 34400
        iptv_streams_port: 34401
        pve_network_trunk_vids: []
        pve_network_netbird_return_route: false
    - name: Desired state as JSON
      ansible.builtin.copy:
        content: "{{ netbird_server_desired | to_json }}"
        dest: "$tmp/desired.json"
        mode: "0600"
PLAY

if ANSIBLE_LOCALHOST_WARNING=false ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/play.log" 2>&1; then
  ok "templates render"
else
  bad "templates render"; tail -20 "$tmp/play.log"; exit 1
fi

# --- server configuration --------------------------------------------------------------------
c=$tmp/config.yaml
has "public address" 'exposedAddress: "https://sync.example.com:443"' "$c"
has "issuer on the public name" 'issuer: "https://sync.example.com/oauth2"' "$c"
has "STUN: Cloudflare" 'uri: "stun:stun.cloudflare.com:3478"' "$c"
has "STUN: Google" 'uri: "stun:stun.l.google.com:19302"' "$c"
hasnt "no local STUN port" "stunPorts" "$c"
has "secret from the secrets dict" 'authSecret: "fake-relay-secret"' "$c"
has "plain HTTP behind Caddy" 'listenAddress: ":80"' "$c"

f=$tmp/Caddyfile
has "Caddy: gRPC over h2c" "reverse_proxy @grpc h2c://netbird-server:80" "$f"
has "Caddy: relay, API and IdP paths" "@backend path /relay* /ws-proxy/* /api/* /oauth2/*" "$f"
has "Caddy: the rest to the dashboard" "reverse_proxy dashboard:80" "$f"
has "Caddy: own TLS for the tunnel origin" "tls internal" "$f"
has "Caddy: no Server header" "header -Server" "$f"
has "Caddy: first party CSP for the dashboard" "header_down Content-Security-Policy \"default-src 'none'; connect-src 'self' https://sync.example.com " "$f"
hasnt "Caddy: no vendor domain in the CSP" "netbird.io" "$f"

d=$tmp/docker-compose.yaml
has "compose: Caddy is the patched build, not upstream's binary" 'image: anvil/caddy:test' "$d"
has "server API on loopback only" '"127.0.0.1:8089:80"' "$d"
has "Caddy on the lab address only" '"192.0.2.115:8443:443"' "$d"
check_ports=$(grep -cE '^\s+- "[0-9.]+:[0-9]+:[0-9]+' "$d")
[ "$check_ports" = 2 ] && ok "two published ports" || bad "two published ports (got $check_ports)"
hasnt "no UDP port" "/udp" "$d"
images=$(grep -cE '^\s+image: .+:[^@]+@sha256:[0-9a-f]{64}$' "$d")
# The server and the dashboard are pinned by digest. Caddy is the patched local build,
# whose tag carries a hash of its Dockerfile (asserted above).
[ "$images" = 2 ] && ok "server and dashboard images, tag and digest" || bad "server and dashboard images, tag and digest (got $images)"
limits=$(grep -c 'mem_limit:' "$d")
[ "$limits" = 3 ] && ok "a memory cap on every service" || bad "a memory cap on every service (got $limits)"
for s in fake-relay-secret FAKEDATASTOREKEY fake-session-key; do
  hasnt "compose file holds no secret ($s)" "$s" "$d"
done
labels=$(grep -c 'anvil.config-sha256: "[0-9a-f]\{64\}"' "$d")
[ "$labels" = 2 ] && ok "config hash labels" || bad "config hash labels (got $labels)"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if docker compose -p t -f "$d" config -q 2>"$tmp/compose.err"; then ok "compose file is valid"
  else bad "compose file is valid"; cat "$tmp/compose.err"; fi
fi

# --- netbird-home unit -------------------------------------------------------------------------
u=$tmp/netbird-home.service
has "home: own state directory" "Environment=NB_STATE_DIR=/var/lib/netbird-home" "$u"
has "home: own nftables table" "Environment=NB_NFTABLES_TABLE=netbird_home" "$u"
has "home: no custom routing rules" "Environment=NB_DISABLE_CUSTOM_ROUTING=true" "$u"
has "home: no eBPF proxy" "Environment=NB_DISABLE_EBPF_WG_PROXY=true" "$u"
has "home: own socket, not under /var/run/netbird/" "--daemon-addr unix:///var/run/netbird-home.sock" "$u"
has "home: after Docker and the cloud client" "After=network-online.target docker.service netbird.service" "$u"
has "home: only with the ip filter table" "nft list table ip filter" "$u"
has "home: memory cap" "MemoryMax=256M" "$u"

# --- return route on the Proxmox host ----------------------------------------------------------
i=$tmp/interfaces
has "pve: the network range routed to the netbird VM" "$(printf '\tpost-up ip route replace 100.64.0.0/16 via 192.0.2.115 dev vmbr0')" "$i"
has "pve: and removed on down" "$(printf '\tpost-down ip route del 100.64.0.0/16 via 192.0.2.115 dev vmbr0 2>/dev/null || true')" "$i"
hasnt "pve: no return route while the switch is off" "ip route replace" "$tmp/interfaces.off"

# --- desired state --------------------------------------------------------------------------------
j=$tmp/desired.json
[ "$(jq -r '.networks[] | select(.name == "lab") | .resources[0].address' "$j")" = "192.0.0.0/16" ] \
  && ok "lab route: the lab's /16" || bad "lab route: the lab's /16"
[ "$(jq -r '.networks[] | select(.name == "lab") | .routers[0].masquerade' "$j")" = true ] \
  && ok "lab route: masquerade on" || bad "lab route: masquerade on"
[ "$(jq -r '.networks[] | select(.name == "home-gateway") | .resources[0].address' "$j")" = "198.51.100.249/32" ] \
  && ok "gateway route: the apps home address" || bad "gateway route: the apps home address"
[ "$(jq -r '.networks[] | select(.name == "home-gateway") | .routers[0].masquerade' "$j")" = false ] \
  && ok "gateway route: masquerade off" || bad "gateway route: masquerade off"
[ "$(jq -c '.nameservers[0] | [.nameservers[0].ip, .domains[0], .groups[0]]' "$j")" = '["198.51.100.249","internal.example.com","operator"]' ] \
  && ok "DNS: Pi-hole for the gateway domain, operator only" || bad "DNS: Pi-hole for the gateway domain"
[ "$(jq -c '[.policies[] | [.sources, .destinations]]' "$j")" = '[[["operator"],["routers"]]]' ] \
  && ok "one policy: operator to routers" || bad "one policy: operator to routers"
[ "$(jq -c '.delete_policies' "$j")" = '["Default"]' ] && ok "the All to All Default policy goes" || bad "Default policy deleted"
[ "$(jq -r '.settings.network_range' "$j")" = "100.64.0.0/16" ] && ok "network range from the site" || bad "network range"

# --- API helper against the stub ------------------------------------------------------------------
helper=ansible/roles/netbird_server/files/netbird_api.py
python3 tests/fixtures/netbird_api_stub.py "$tmp/port" "$tmp/writes" & stub_pid=$!
disown "$stub_pid"
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
api="http://127.0.0.1:$(cat "$tmp/port")/api"
call() { python3 "$helper" >"$tmp/out" 2>&1; }

echo "{\"api\": \"$api\", \"action\": \"status\"}" | call
[ "$(jq -r .setup_required "$tmp/out")" = true ] && ok "helper: setup required at first" || bad "helper: status"

echo "{\"api\": \"$api\", \"action\": \"setup\", \"check\": true, \"email\": \"admin@example.com\", \"password\": \"x\", \"name\": \"owner\", \"pat_days\": 365}" | call
[ ! -s "$tmp/writes" ] && ok "helper: check mode sends nothing" || bad "helper: check mode sends nothing"

echo "{\"api\": \"$api\", \"action\": \"setup\", \"email\": \"admin@example.com\", \"password\": \"x\", \"name\": \"owner\", \"pat_days\": 365}" | call
[ "$(jq -r .secrets.api_token "$tmp/out")" = nbp_stubtoken ] && ok "helper: setup returns the token" || { bad "helper: setup"; cat "$tmp/out"; }

req() { jq -n --arg api "$api" --argjson d "$(cat "$j")" --argjson check "$1" \
  '{api: $api, action: "reconcile", check: $check, token: "nbp_stubtoken", desired: $d, pat_days: 365, pat_renew_days: 30}'; }
: >"$tmp/writes"
req true | call
[ ! -s "$tmp/writes" ] && ok "helper: reconcile check mode sends nothing" || bad "helper: reconcile check mode"
[ "$(jq '.changed | length' "$tmp/out")" -gt 0 ] && ok "helper: check mode lists the changes" || bad "helper: check mode lists the changes"
req false | call
jq -e '.error' "$tmp/out" >/dev/null && { bad "helper: reconcile"; cat "$tmp/out"; }
grep -q "^DELETE /policies/" "$tmp/writes" && ok "helper: Default policy deleted" || bad "helper: Default policy deleted"
jq -e '.changed | index("owner user: auto groups")' "$tmp/out" >/dev/null && ok "helper: owner's devices join operator" || bad "helper: owner auto groups"
jq -e '.warnings | length == 0' "$tmp/out" >/dev/null && ok "helper: no All to All policy left" || bad "helper: All to All left"
hasnt "helper: output names no address" "198.51.100.249" "$tmp/out"
: >"$tmp/writes"
req false | call
[ "$(jq '.changed | length' "$tmp/out")" = 0 ] && [ ! -s "$tmp/writes" ] && ok "helper: second run changes nothing" \
  || { bad "helper: second run changes nothing"; cat "$tmp/out" "$tmp/writes"; }

key() { echo "{\"api\": \"$api\", \"action\": \"setup_key\", \"token\": \"nbp_stubtoken\", \"name\": \"netbird-home\", \"auto_groups\": [\"routers\"], \"expires_in\": 86400}" | call; }
key; first=$(jq -r .secrets.setup_key "$tmp/out")
key; second=$(jq -r .secrets.setup_key "$tmp/out")
[ -n "$first" ] && [ "$first" != "$second" ] && ok "helper: a new setup key each time" || bad "helper: setup key"
jq -e '.changed | index("setup key netbird-home: revoke an older one")' "$tmp/out" >/dev/null \
  && ok "helper: the older key is revoked" || bad "helper: older key revoked"

echo "{\"api\": \"$api\", \"action\": \"reconcile\", \"token\": \"wrong\", \"desired\": {}}" | call
rc=$?
[ $rc -ne 0 ] && jq -e '.error' "$tmp/out" >/dev/null && ok "helper: an API error fails with a message" || bad "helper: API error"

exit $fail
