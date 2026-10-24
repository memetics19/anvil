#!/usr/bin/env bash
# Docmost (role docmost): the templates render, the secrets stay in the env files (each
# container gets only its own), the port is published on the lab address only, and the
# images are pinned. Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: Docmost templates
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: frigate
    site: {hosts: {frigate: {ip: 192.0.2.14}}}
    gateway_domain: internal.example.com
    docmost_secrets: {app_secret: test-app-secret, db_password: test-db-password}
  vars_files:
    - $PWD/ansible/roles/docmost/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/docmost/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0600"
      loop: [docker-compose.yaml, docmost.env, db.env]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi

c=$tmp/docker-compose.yaml
check "compose: valid YAML with docmost, db and redis" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"$c\"))[\"services\"]; assert sorted(s)==[\"db\",\"docmost\",\"redis\"]'"
check "compose: no secret value in the compose file" "! grep -q -E 'test-app-secret|test-db-password' '$c'"
check "compose: only Docmost is published, on the lab address" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"$c\"))[\"services\"]; assert s[\"docmost\"][\"ports\"]==[\"192.0.2.14:3000:3000\"]; assert \"ports\" not in s[\"db\"] and \"ports\" not in s[\"redis\"]'"
check "compose: APP_URL is the gateway name over https" "grep -q 'APP_URL: \"https://wiki.internal.example.com\"' '$c'"
check "compose: every image is pinned by digest" "[ \$(grep -c 'image: .*@sha256:[a-f0-9]\{64\}' '$c') = 3 ]"
check "compose: Docmost waits for a healthy db and redis" \
  "python3 -c 'import yaml; d=yaml.safe_load(open(\"$c\"))[\"services\"][\"docmost\"][\"depends_on\"]; assert d==dict(db={\"condition\":\"service_healthy\"},redis={\"condition\":\"service_healthy\"})'"
check "compose: memory capped with no swap on every service" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"$c\"))[\"services\"]; assert all(v[\"mem_limit\"]==v[\"memswap_limit\"] for v in s.values())'"
check "docmost.env: app secret and database URL, no Postgres password variable" \
  "grep -qx 'APP_SECRET=test-app-secret' '$tmp/docmost.env' && grep -q '^DATABASE_URL=postgresql://docmost:test-db-password@db:5432/docmost' '$tmp/docmost.env' && ! grep -q POSTGRES_PASSWORD '$tmp/docmost.env'"
check "db.env: only the Postgres password" \
  "[ \"\$(grep -v '^#' '$tmp/db.env')\" = 'POSTGRES_PASSWORD=test-db-password' ]"
check "compose: each container reads only its own env file" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"$c\"))[\"services\"]; assert s[\"docmost\"][\"env_file\"]==\"docmost.env\" and s[\"db\"][\"env_file\"]==\"db.env\" and \"env_file\" not in s[\"redis\"]'"

[ "$fail" = 0 ] && echo "PASS: docmost" || echo "FAIL: docmost"
exit "$fail"
