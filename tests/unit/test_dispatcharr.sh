#!/usr/bin/env bash
# Dispatcharr (role dispatcharr) and its VM: the image pinned, published only on the lab
# address, the gateway trusted as its proxy, no password in the compose file or on a
# command line, its web page behind single sign-on, its port guarded, and the VM wired into
# Terraform, the inventory and the playbook. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/dispatcharr

cat >"$tmp/inv.yml" <<'INV'
all:
  children:
    apps_servers:
      hosts: {apps: {}}
    dispatcharr_servers:
      hosts: {dispatcharr: {}}
INV
cat >"$tmp/play.yml" <<PLAY
- name: Render Dispatcharr
  hosts: dispatcharr
  gather_facts: false
  connection: local
  vars_files: [$r/defaults/main.yml]
  vars:
    site:
      hosts:
        apps: {ip: 192.0.2.121}
        dispatcharr: {ip: 192.0.2.133}
  tasks:
    - ansible.builtin.template: {src: "$r/templates/docker-compose.yaml.j2", dest: "$tmp/docker-compose.yaml", mode: "0600"}
      delegate_to: localhost
PLAY
if ansible-playbook -i "$tmp/inv.yml" "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "compose renders"; else bad_ "compose renders"; cat "$tmp/render.log"; exit 1; fi
c=$tmp/docker-compose.yaml
t=$r/tasks/main.yml

# compose
check "image pinned to a digest" "grep -qE '^    image: ghcr.io/dispatcharr/dispatcharr:[0-9.]+@sha256:[0-9a-f]{64}$' '$c'"
check "published only on the lab address" "grep -qx '      - \"192.0.2.133:9191:9191\"' '$c' && [ \$(grep -c ':9191' '$c') = 1 ]"
check "the gateway is its trusted proxy" "grep -qx '      DISPATCHARR_TRUSTED_PROXIES: \"192.0.2.121\"' '$c'"
check "memory capped, swap included" "grep -qx '    mem_limit: 2g' '$c' && grep -qx '    memswap_limit: 2g' '$c'"
check "no new privileges" "grep -qx '      - no-new-privileges:true' '$c'"
check "no password in the compose file" "! grep -v '^ *#' '$c' | grep -qiE 'password|secret'"
check "the database password comes from a root-only file" "grep -qx '      - path: ./dispatcharr.env' '$c' && grep -A6 'dispatcharr.env\"\$' '$t' | grep -q 'mode: \"0600\"'"

# secrets
check "passwords generated straight into Vault" "grep -q 'openssl rand -hex 24 | tr -d' '$t' && grep -q \"\\['admin_password', 'db_password'\\]\" '$t'"
check "the admin password is passed by name, not on the command line" "grep -A6 'docker$' '$t' | grep -qx '      - ANVIL_ADMIN_PASSWORD' && grep -q 'ANVIL_ADMIN_PASSWORD: \"{{ dispatcharr_secrets.admin_password }}\"' '$t'"
check "every task that holds a password is no_log" "[ \$(grep -c 'no_log: true' '$t') -ge 4 ]"
check "the admin is created only when there is none" "grep -q 'filter(is_superuser=True).exists()' '$t'"
check "players on the VPN may fetch playlists, set once" "grep -qx 'dispatcharr_m3u_epg_extra_cidrs: \\[100.64.0.0/10\\]' '$r/defaults/main.yml' && grep -q 'LOCAL_NETWORK_CIDRS as local' '$t' && grep -q \"'M3U_EPG' in c.get_network_access_settings()\" '$t'"

# wiring
check "behind single sign-on, players' paths open" "! grep -qE '^caddy_sso_exempt: \\[.*\\bdispatcharr\\b' ansible/roles/caddy/defaults/main.yml && grep -qE '^  dispatcharr: \\[/output, /output/\\*, /proxy' ansible/roles/caddy/defaults/main.yml"
check "Dispatcharr signs in the Authentik user by email" "grep -qx 'dispatcharr_proxy_auth_header: X-Authentik-Email' '$r/defaults/main.yml' && grep -q \"'header': os.environ\\['ANVIL_HEADER'\\]\" '$t'"
check "port guarded" "grep -qx 'port_guard_ports: \\[9191\\]' ansible/inventory/host_vars/dispatcharr.yml"
check "VM in Terraform with the module" "grep -q 'source = \"./modules/ubuntu_vm\"' terraform/vm_dispatcharr.tf && grep -q '\"dispatcharr\"' terraform/images.tf"
check "inventory group and node_exporter" "grep -q '^    dispatcharr_servers:' ansible/inventory/hosts.yml && awk '/^    node_exporter:/{p=1} p&&/^    [a-z_]+:\$/&&!/node_exporter/{exit} p' ansible/inventory/hosts.yml | grep -q '^        dispatcharr:'"
check "playbook play with port_guard first" "grep -A6 '^- name: Dispatcharr' ansible/playbooks/vms.yml | grep -A1 'role: port_guard' | grep -q dispatcharr"
check "smoke tests allow its port" "grep -q 'dispatcharr: \\[docker-proxy/9191\\]' tests/smoke/security.yml"
check "site example has the host and the route" "grep -q '^    dispatcharr: {node: pve2' site/site.example.yml && grep -q 'name: dispatcharr, host: hosts.dispatcharr.ip, port: 9191' site/site.example.yml"

[ "$fail" = 0 ] && echo "PASS: dispatcharr" || echo "FAIL: dispatcharr"
exit "$fail"
