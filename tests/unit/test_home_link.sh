#!/usr/bin/env bash
# The home link (role home_link) and Switchy in Hermes: only the home subnet goes through the
# tunnel, never a default route, its settings are root-only and never logged, and it does
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
w=$r/templates/wg.conf.j2
h=ansible/roles/hermes/tasks/main.yml

check "only the home subnet is routed through the tunnel" "grep -qx 'AllowedIPs = {{ home_link_peer.home_subnet }}' $w"
check "the tunnel never takes the default route" "! grep -qE '0\.0\.0\.0/0|::/0' $w $t $r/defaults/main.yml"
check "the home subnet must be private" "grep -q \"home_subnet | default('') is match('^(10|192\" $t"
check "nothing happens until the router's peer is in Vault" "grep -q \"when: home_link_peer.private_key | default('') | length > 0\" $t"
check "its settings are root-only and never logged" "awk '/The link.s settings/,/notify:/' $t | grep -q 'mode: \"0600\"' && awk '/The link.s settings/,/notify:/' $t | grep -q 'no_log: true'"
check "the Switchy server is not in this repo" "! git ls-files | grep -q 'switchy_mcp'"
check "the Switchy panel list comes from Vault and is never logged" "awk '/The Switchy panel list/,/no_log/' $h | grep -q 'hermes_switchy_vault_path'"
check "Switchy is untrusted (switching asks first)" "awk '/MCP servers this run/,/else hermes_mcp_servers/' $h | grep -q \"'trust': 'untrusted'\""
check "the home link runs before Hermes" "awk '/^- name: Hermes$/,0' ansible/playbooks/vms.yml | grep -A3 'roles:' | grep -q 'role: home_link'"

[ "$fail" = 0 ] && echo "PASS: home link" || { echo "FAIL: home link"; exit 1; }
