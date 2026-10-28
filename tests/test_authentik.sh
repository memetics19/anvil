#!/usr/bin/env bash
# Authentik (role authentik): the templates render, the secrets stay in the mode 600 env
# files (Postgres gets only its own), only the HTTP port is published, on the lab address,
# the images are pinned, the memory caps fit the VM, and the role is wired into vms.yml, the
# gateway example and Homepage. Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: Authentik templates
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: identity
    site:
      email: admin@example.com
      hosts: {identity: {ip: 192.0.2.125, home_ip: 198.51.100.48}, apps: {ip: 192.0.2.121}}
    authentik_secrets:
      secret_key: test-secret-key
      postgres_password: test-postgres-password
      bootstrap_password: test-bootstrap-password
      bootstrap_token: test-bootstrap-token
  vars_files:
    - $PWD/ansible/roles/authentik/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/authentik/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0600"
      loop: [docker-compose.yaml, authentik.env, db.env]
    - ansible.builtin.copy:
        content: "{{ authentik_vault_path }} {{ authentik_secret_keys | join(',') }}"
        dest: $tmp/vault
        mode: "0600"
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi

c=$tmp/docker-compose.yaml
secrets='test-secret-key|test-postgres-password|test-bootstrap-password|test-bootstrap-token'
# shellcheck disable=SC2329  # called through check's eval
py() { python3 -c "import yaml; s=yaml.safe_load(open('$c'))['services']; $1"; }

check "compose: valid YAML with server, worker and db (no Redis since 2025.10)" \
  "py 'assert sorted(s)==[\"db\",\"server\",\"worker\"]'"
check "compose: no secret value in the compose file" "! grep -q -E '$secrets' '$c'"
check "compose: only the server is published, port 9000 on the lab address" \
  "py 'assert s[\"server\"][\"ports\"]==[\"192.0.2.125:9000:9000\"]; assert \"ports\" not in s[\"worker\"] and \"ports\" not in s[\"db\"]'"
check "compose: nothing on the home address, no 9443 and no LDAP port" \
  "! grep -v '^ *#' '$c' | grep -q -E '198\.51\.100\.48|9443|:389|:636|:3389|:6636'"
check "compose: every image is pinned by digest" "[ \$(grep -c 'image: .*@sha256:[a-f0-9]\{64\}' '$c') = 3 ]"
check "compose: server and worker run the same Authentik image" \
  "py 'assert s[\"server\"][\"image\"]==s[\"worker\"][\"image\"] and s[\"server\"][\"image\"].startswith(\"ghcr.io/goauthentik/server:\")'"
check "compose: server and worker wait for a healthy db" \
  "py 'assert all(s[n][\"depends_on\"]==dict(db={\"condition\":\"service_healthy\"}) for n in (\"server\",\"worker\"))'"
check "compose: memory capped with no swap on every service" \
  "py 'assert all(v[\"mem_limit\"]==v[\"memswap_limit\"] for v in s.values())'"
check "compose: the caps add up to at most 2 GB of the VM's 3 GB" \
  "py 'assert sum(int(v[\"mem_limit\"].rstrip(\"m\")) for v in s.values()) <= 2048'"
check "compose: the worker has no Docker socket and does not run as root" \
  "py 'w=s[\"worker\"]; assert \"user\" not in w and not any(\"docker.sock\" in v for v in w[\"volumes\"])'"
check "compose: forwarded headers trusted from the gateway's lab address only" \
  "py 'assert all(s[n][\"environment\"][\"AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS\"]==\"192.0.2.121/32\" for n in (\"server\",\"worker\"))'"
check "compose: each container reads only its own env file" \
  "py 'assert s[\"server\"][\"env_file\"]==s[\"worker\"][\"env_file\"]==\"authentik.env\" and s[\"db\"][\"env_file\"]==\"db.env\"'"
check "authentik.env: the four secrets and the bootstrap email, no Postgres password variable" \
  "grep -qx 'AUTHENTIK_SECRET_KEY=test-secret-key' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_POSTGRESQL__PASSWORD=test-postgres-password' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_BOOTSTRAP_PASSWORD=test-bootstrap-password' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_BOOTSTRAP_TOKEN=test-bootstrap-token' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_BOOTSTRAP_EMAIL=admin@example.com' '$tmp/authentik.env' &&
   ! grep -q POSTGRES_PASSWORD '$tmp/authentik.env'"
check "db.env: only the Postgres password" \
  "[ \"\$(grep -v '^#' '$tmp/db.env')\" = 'POSTGRES_PASSWORD=test-postgres-password' ]"
check "vault: kv/homelab/identity/authentik with the four keys" \
  "[ \"\$(cat '$tmp/vault')\" = 'homelab/identity/authentik secret_key,postgres_password,bootstrap_password,bootstrap_token' ]"

# The role's tasks: env files mode 600 and never logged, secrets only added, the health check.
t=ansible/roles/authentik/tasks/main.yml
# shellcheck disable=SC2329  # called through check's eval
tpy() { python3 -c "import yaml; t={x['name']: x for x in yaml.safe_load(open('$t'))}; $1"; }
check "tasks: env files are written mode 0600 with no_log and no diff" \
  "tpy 'x=t[\"Env files (secrets from Vault)\"]; assert x[\"ansible.builtin.copy\"][\"mode\"]==\"0600\" and x[\"no_log\"] is True and x[\"diff\"] is False'"
check "tasks: the secrets are read with no_log" "tpy 'assert t[\"Read the Authentik secrets from Vault\"][\"no_log\"] is True'"
check "tasks: only missing keys are generated, an empty path with put -cas=0" \
  "tpy 'x=t[\"Generate the missing secrets into Vault\"]; assert \"put -cas=0\" in x[\"ansible.builtin.shell\"][\"cmd\"] and \"difference(authentik_vault_keys)\" in x[\"vars\"][\"authentik_missing\"]'"
check "tasks: the run ends on the health endpoint" \
  "tpy 'assert t[\"Authentik answers\"][\"ansible.builtin.uri\"][\"url\"].endswith(\"/-/health/ready/\")'"

# Wiring: vms.yml (after the Docker play), the gateway example and the Homepage catalog.
check "vms.yml: role authentik with tag authentik on identity_servers, after Docker" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/vms.yml\")); n=[x[\"name\"] for x in p]
i=[k for k,x in enumerate(p) if any(r.get(\"role\")==\"authentik\" for r in x.get(\"roles\",[]))]
assert len(i)==1 and p[i[0]][\"hosts\"]==\"identity_servers\" and i[0]>n.index(\"Docker\")
assert [r for r in p[i[0]][\"roles\"] if r[\"role\"]==\"authentik\"][0][\"tags\"]==[\"authentik\"]'"
check "site.example.yml: the auth entry points at the identity VM's lab address" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"site/site.example.yml\"))[\"site\"][\"services\"]; a=[x for x in s if x[\"name\"]==\"auth\"]
assert a==[dict(name=\"auth\",host=\"hosts.identity.ip\",port=9000,scheme=\"http\",websocket=True)]'"
check "homepage: catalog entry auth in Security, no widget" \
  "python3 -c 'import yaml; c=yaml.safe_load(open(\"ansible/roles/homepage/defaults/main.yml\"))[\"homepage_catalog\"][\"auth\"]
assert c==dict(title=\"Authentik\",group=\"Security\",icon=\"authentik.png\",description=\"Single sign-on\",widget=\"none\")'"

[ "$fail" = 0 ] && echo "PASS: authentik" || echo "FAIL: authentik"
exit "$fail"
