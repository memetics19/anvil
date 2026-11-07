#!/usr/bin/env bash
# Pi-hole's exporter (role pihole, pihole_exporter_*): a pinned container on the project's own
# network that reaches Pi-hole by name, logs in with the web password from a mode 600 env file,
# and publishes its metrics on the lab address only. Off: no exporter. Renders locally with
# documentation addresses and a made-up password.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/pihole
pw=$(python3 -c 'import secrets; print(secrets.token_hex(16))')

cat >"$tmp/play.yml" <<PLAY
- name: Render Pi-hole's compose file
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    inventory_hostname: apps
    site: {domain: example.com, hosts: {apps: {ip: 192.0.2.121, home_ip: 198.51.100.249, dns_subnet: 192.0.2.128/26, dns_unbound_ip: 192.0.2.130}}}
    pihole_secrets: {web_password: "$pw"}
  tasks:
    - ansible.builtin.template: {src: "$r/templates/docker-compose.yaml.j2", dest: "$tmp/on.yaml", mode: "0600"}
    - ansible.builtin.template: {src: "$r/templates/docker-compose.yaml.j2", dest: "$tmp/off.yaml", mode: "0600"}
      vars: {pihole_exporter_enabled: false}
    - ansible.builtin.template: {src: "$r/templates/exporter.env.j2", dest: "$tmp/exporter.env", mode: "0600"}
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "it renders"; else bad_ "it renders"; cat "$tmp/render.log"; exit 1; fi
e=$tmp/exporter.yaml
awk '/^  exporter:/{on=1; next} on && /^  [a-z]/ {exit} on && /^[a-z]/ {exit} on {print}' "$tmp/on.yaml" >"$e"

check "the image is pinned to a digest" "grep -q 'image: ekofr/pihole-exporter:v[0-9.]*@sha256:[0-9a-f]\{64\}' $e"
check "it reaches Pi-hole by name on the project's network" \
  "grep -q 'PIHOLE_HOSTNAME: pihole' $e && grep -A1 '^    networks:' $e | grep -q -- '- dns'"
check "its metrics are published on the lab address only" \
  "grep -q '\"192.0.2.121:9617:9617/tcp\"' $e && ! grep -q '198.51.100.249' $e"
check "the login comes from exporter.env, not the compose file" \
  "grep -q 'path: exporter.env' $e && ! grep -q '$pw' $tmp/on.yaml"
check "exporter.env holds the password and nothing else" "[ \"\$(cat $tmp/exporter.env)\" = \"PIHOLE_PASSWORD=$pw\" ]"
check "exporter.env is written mode 600" "grep -A8 'name: Exporter env file' $r/tasks/main.yml | grep -q 'mode: \"0600\"'"
check "read-only, no new privileges, memory capped" \
  "grep -q 'read_only: true' $e && grep -q 'no-new-privileges:true' $e && grep -q 'mem_limit: 64m' $e"
check "off: no exporter" "! grep -q 'pihole-exporter' $tmp/off.yaml"

[ "$fail" = 0 ] && echo "PASS: pihole exporter"
exit "$fail"
