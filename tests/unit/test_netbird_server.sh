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
cd "$(dirname "$0")/../.." || exit 1

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
    - $PWD/ansible/inventory/group_vars/all/iptv.yml
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
      admin_sources: [192.0.2.31/32]
      admin_vpn_sources: [100.64.7.9/32]
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
        pve_network_netbird_forward: true
        pve_network_netbird_https_port: 8443
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
has "Caddy: gRPC over h2c from anywhere" "reverse_proxy h2c://netbird-server:80" "$f"
has "Caddy: relay and login pages from anywhere" "@open path /relay* /oauth2/*" "$f"
has "Caddy: the operator's devices only, from site.admin_sources and admin_vpn_sources" "@operator remote_ip 192.0.2.31/32 100.64.7.9/32" "$f"
has "Caddy: API and WebSocket proxy for the operator" "@backend path /ws-proxy/* /api/*" "$f"
has "Caddy: the rest to the dashboard" "reverse_proxy dashboard:80" "$f"
has "Caddy: everyone else gets 404" "respond 404" "$f"
awk '/handle @operator/{p=1} p' "$f" | grep -q "reverse_proxy dashboard:80" && ok "Caddy: the dashboard only inside the operator block" || bad "Caddy: the dashboard only inside the operator block"
[ "$(grep -c "reverse_proxy dashboard:80" "$f")" = 1 ] && ok "Caddy: one dashboard route" || bad "Caddy: one dashboard route"
has "Caddy: Let's Encrypt over TLS-ALPN" "disable_http_challenge" "$f"
has "Caddy: its own CA until the name points here" "issuer internal" "$f"
hasnt "Caddy: no DNS token on this VM" "dns cloudflare" "$f"
has "Caddy: access log with client addresses" "format json" "$f"
has "Caddy: no Server header" "header -Server" "$f"
has "Caddy: first party CSP for the dashboard" "header_down Content-Security-Policy \"default-src 'none'; connect-src 'self' https://sync.example.com " "$f"
hasnt "Caddy: no vendor domain in the CSP" "netbird.io" "$f"

d=$tmp/docker-compose.yaml
has "compose: Caddy is the patched build, not upstream's binary" 'image: anvil/caddy:test' "$d"
has "server API on loopback only" '"127.0.0.1:8089:80"' "$d"
has "Caddy on the lab address only" '"192.0.2.115:8443:443"' "$d"
check_ports=$(grep -cE '^\s+- "[0-9.]+:[0-9]+:[0-9]+' "$d")
[ "$check_ports" = 3 ] && ok "three published ports" || bad "three published ports (got $check_ports)"
has "Caddy on the loopback too, for this VM's own client" '"127.0.0.1:443:443"' "$d"
grep -q '127.0.0.1 {{ site.netbird_domain }} # anvil: netbird_server' ansible/roles/netbird_server/tasks/server.yml && ok "the public name is the loopback on this VM" || bad "hosts entry"
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
has "pve: TCP 443 on the uplink address to Caddy on the netbird VM" "iptables -t nat -A PREROUTING -d 198.51.100.250/32 -p tcp --dport 443 -j DNAT --to-destination 192.0.2.115:8443" "$tmp/interfaces"
has "pve: the forward accepted only for the DNATed connection" "iptables -A FORWARD -i vmbr0 -d 192.0.2.115/32 -p tcp --dport 8443 -m conntrack --ctstate DNAT -j ACCEPT" "$tmp/interfaces"
hasnt "pve: no masquerade for it, the client's address stays" "MASQUERADE" "$tmp/interfaces"
[ "$(grep -o 'dport 443 -j DNAT' "$tmp/interfaces" | wc -l | tr -d ' ')" = 4 ] && ok "pve: each 443 rule checked before it is added, and every copy removed" || bad "pve: 443 rule lines"
hasnt "pve: no forward while the switch is off" "dport 443" "$tmp/interfaces.off"
grep -qx 'pve_network_netbird_https_port: 8443' ansible/roles/pve_network/defaults/main.yml && grep -qx 'netbird_server_https_port: 8443' ansible/roles/netbird_server/defaults/main.yml && ok "pve forwards to the port Caddy listens on" || bad "pve forward port and Caddy's port differ"

n=ansible/roles/netbird_server/templates/netbird-reply.nft.j2
u=ansible/roles/netbird_server/templates/anvil-netbird-reply.service.j2
has "netbird VM: forwarded Caddy connections marked" "tcp dport {{ netbird_server_https_port }} ct state new ct mark set {{ netbird_server_reply_mark }}" "$n"
has "netbird VM: their replies carry the mark, and only the replies" "ct direction reply ct mark {{ netbird_server_reply_mark }} meta mark set {{ netbird_server_reply_mark }}" "$n"
has "netbird VM: the marked replies use their own table" "fwmark {{ netbird_server_reply_mark }} lookup {{ netbird_server_reply_table }}" "$u"
has "netbird VM: that table holds only the way back to the Proxmox host" "ip route replace default via {{ site.pve.gateway_alias_ip }} table {{ netbird_server_reply_table }}" "$u"
grep -qx 'netbird_server_reply_table: 2601' ansible/roles/netbird_server/defaults/main.yml && ok "netbird VM: not NetBird's table (7120)" || bad "reply table"
grep -qx 'netbird_server_reply_rule_priority: 100' ansible/roles/netbird_server/defaults/main.yml && ok "netbird VM: the reply rule comes before NetBird's rules (105, 110)" || bad "reply rule priority"
hasnt "netbird VM: the mark is not NetBird's own" "0x1bd00" ansible/roles/netbird_server/defaults/main.yml
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
# Live TV away from home: the IPTV playlist points at the host's home address. Masquerade off,
# so the IPTV VM answers through the host (the return route), not straight to the routing peer.
[ "$(jq -r '.networks[] | select(.name == "home-tv") | .resources[0].address' "$j")" = "198.51.100.250/32" ] \
  && ok "tv route: the host's home address" || bad "tv route: the host's home address"
[ "$(jq -r '.networks[] | select(.name == "home-tv") | .routers[0].masquerade' "$j")" = false ] \
  && ok "tv route: masquerade off" || bad "tv route: masquerade off"
[ "$(jq -c '.nameservers[0] | [.nameservers[0].ip, .domains[0], .groups[0]]' "$j")" = '["198.51.100.249","internal.example.com","operator"]' ] \
  && ok "DNS: Pi-hole for the gateway domain" || bad "DNS: Pi-hole for the gateway domain"
[ "$(jq -c '[.policies[] | [.name, .sources, .destinations, (.protocol // "all"), (.ports // [])]]' "$j")" = '[["operator-to-routers",["operator"],["routers","lab","gateway","live-tv"],"all",[]],["operator-to-operator",["operator"],["operator"],"all",[]],["tv-to-gateway",["tv"],["gateway"],"tcp",[443]],["tv-to-live-tv",["tv"],["live-tv"],"tcp",[34400,34401]]]' ] \
  && ok "policies: the operator everywhere, televisions to HTTPS on the gateway and the live TV ports only" || { bad "policies"; jq -c '.policies' "$j"; }
[ "$(jq -c '[.networks[].resources[].groups]' "$j")" = '[["lab"],["gateway"],["live-tv"]]' ] \
  && ok "each routed network in its own resource group" || bad "each routed network in its own resource group"
[ "$(jq -c '.nameservers[0].groups' "$j")" = '["operator","tv"]' ] && ok "Pi-hole for the operator and televisions" || bad "Pi-hole groups"
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
