#!/usr/bin/env bash
# The home link (role home_link, an OpenVPN client of the home router) and Switchy in Hermes:
# only the home subnet goes through the tunnel, never a default route, its settings are root-only and never logged, and it does
# nothing until its Vault entry exists. The Switchy server stays out of this repo, its panel
# list comes from Vault, and it is untrusted like every other MCP server. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

r=ansible/roles/home_link
t=$r/tasks/main.yml
w=$r/templates/client.conf.j2
h=ansible/roles/hermes/tasks/main.yml

check "only the home subnet is routed, pushed routes are ignored" "grep -qx 'route-nopull' $w && grep -q '^route {{ home_link_peer.home_subnet' $w && grep -q 'pull-filter ignore \"redirect-gateway\"' $w"
check "the router's CA block, route and script lines are dropped" "grep -q 'startswith(.<ca>.)' $w && grep -q \"startswith(('remote-cert-tls', 'redirect-gateway', 'route ', 'route-ipv6', 'dhcp-option', 'up ', 'down ', 'script-security'))\" $w"
check "the server is pinned by certificate fingerprint, not the weak CA" "grep -q '^peer-fingerprint {{ home_link_peer.peer_fingerprint }}' $w"
check "an old server's data cipher is honoured" "grep -qx 'data-ciphers-fallback AES-128-CBC' $w"
check "the tunnel never takes the default route" "! grep -qE '0\.0\.0\.0/0|::/0' $w $t $r/defaults/main.yml"
check "the home subnet must be private" "grep -q \"home_subnet | default('') is match('^(10|192\" $t"
check "nothing happens until config, remote and fingerprint are in Vault" "grep -q 'home_link_peer.config | default' $t && grep -q 'home_link_peer.remote | default' $t && grep -q 'home_link_peer.peer_fingerprint | default' $t"
check "its settings are root-only and never logged" "awk '/The link.s settings/,/notify:/' $t | grep -q 'mode: \"0600\"' && awk '/The link.s settings/,/notify:/' $t | grep -q 'no_log: true'"
check "the Switchy server is not in this repo" "! git ls-files | grep -q 'switchy_mcp'"
check "the Switchy panel list comes from Vault and is never logged" "awk '/The Switchy panel list/,/no_log/' $h | grep -q 'hermes_switchy_vault_path'"
check "Switchy and lab are full-trust (home control and read-only lab, no per-call prompt)" "awk '/Read-only lab joins/,/else hermes_mcp_base/' $h | grep -c \"'trust': 'full'\" | grep -q 2"
check "the shop MCPs stay untrusted (ordering asks first)" "grep -c 'trust: untrusted' ansible/roles/hermes/defaults/main.yml | grep -q 7"
check "the home link runs before Hermes" "awk '/^- name: Hermes$/,0' ansible/playbooks/vms.yml | grep -A3 'roles:' | grep -q 'role: home_link'"

[ "$fail" = 0 ] && echo "PASS: home link" || { echo "FAIL: home link"; exit 1; }
