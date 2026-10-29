#!/usr/bin/env bash
# Proxmox single sign-on (role pve_sso): the realm settings, when the role runs at all, the
# hosts entry, and that the client key goes only on stdin. Runs the role's defaults locally
# with a fixture site dict. Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# render <services-yaml-flow> -> $tmp/out.json with the values the role uses
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: pve_sso values
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/inventory/group_vars/all/gateway.yml
    - $PWD/ansible/roles/pve_sso/defaults/main.yml
  vars:
    site:
      domain: example.com
      gateway: {subdomain: internal}
      hosts: {apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}}
      services: $1
  tasks:
    - ansible.builtin.copy:
        content: >-
          {{ {'enabled': pve_sso_enabled | bool, 'name': pve_sso_auth_name, 'ip': pve_sso_gateway_ip,
              'group': pve_sso_pve_group, 'ceph': pve_sso_ceph_enabled | bool,
              'ceph_url': pve_sso_ceph_url, 'ceph_metadata': pve_sso_ceph_metadata,
              'realm': pve_sso_realm_options | combine({'realm': pve_sso_realm, 'client-key': 'test-client-key'})} | to_json }}
        dest: $tmp/out.json
        mode: "0600"
PLAY
  rm -f "$tmp/out.json"
  ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1
}
j() { python3 -c "import json; d=json.load(open('$tmp/out.json')); $1"; }

render '[{name: auth, host: hosts.identity.ip, port: 9000, scheme: http}, {name: pve, host: pve.ip, port: 8006, scheme: https}, {name: ceph, host: pve.ip, port: 8443, scheme: https}]'
if [ -s "$tmp/out.json" ]; then ok "values render"; else bad_ "values render"; cat "$tmp/log"; exit 1; fi
check "on when site.services has an auth entry" "j 'assert d[\"enabled\"] is True'"
check "Authentik's name under the gateway domain, at the gateway's home address" \
  "j 'assert d[\"name\"]==\"auth.internal.example.com\" and d[\"ip\"]==\"198.51.100.249\"'"
check "realm: OpenID Connect against Authentik's proxmox app" \
  "j 'r=d[\"realm\"]; assert r[\"type\"]==\"openid\" and r[\"realm\"]==\"authentik\" and r[\"client-id\"]==\"proxmox\"
assert r[\"issuer-url\"]==\"https://auth.internal.example.com/application/o/proxmox/\"'"
check "realm: users and groups follow Authentik on every login" \
  "j 'r=d[\"realm\"]; assert r[\"autocreate\"] is True and r[\"groups-claim\"]==\"groups\" and r[\"groups-autocreate\"] is True and r[\"groups-overwrite\"] is True'"
check "realm: the user name is Authentik's user name" "j 'assert d[\"realm\"][\"username-claim\"]==\"preferred_username\"'"
check "the Proxmox group is named the way Proxmox names a claimed group" "j 'assert d[\"group\"]==\"lab-admins-authentik\"'"
# (Compared once the authentik role has these defaults.)
check "the client id, group and auth name match the authentik role's" \
  "python3 -c 'import yaml; a=yaml.safe_load(open(\"ansible/roles/authentik/defaults/main.yml\")); p=yaml.safe_load(open(\"ansible/roles/pve_sso/defaults/main.yml\"))
for ak, pk in [(\"authentik_proxmox_client_id\", \"pve_sso_client_id\"), (\"authentik_sso_group\", \"pve_sso_group\"), (\"authentik_auth_name\", \"pve_sso_auth_route\")]:
    assert a.get(ak, p[pk])==p[pk], ak'"

check "Ceph: on with a ceph entry, SAML at its gateway name, metadata from Authentik's ceph app" \
  "j 'assert d[\"ceph\"] is True and d[\"ceph_url\"]==\"https://ceph.internal.example.com\"
assert d[\"ceph_metadata\"]==\"https://auth.internal.example.com/application/saml/ceph/metadata/\"'"
render '[{name: pve, host: pve.ip, port: 8006, scheme: https}]'
check "off without an auth entry" "j 'assert d[\"enabled\"] is False'"
check "Ceph: off without a ceph entry" "j 'assert d[\"ceph\"] is False'"

render '[{name: auth, host: hosts.identity.ip, port: 9000, scheme: http, enabled: false}]'
check "off when the auth entry is disabled" "j 'assert d[\"enabled\"] is False'"

# The tasks: the key only on stdin, never logged, Perl's \$_ not expanded.
t=ansible/roles/pve_sso/tasks/main.yml
# shellcheck disable=SC2329  # called through check's eval
tpy() { python3 -c "import yaml; t={x['name']: x for x in yaml.safe_load(open('$t'))}; $1"; }
check "realm task: settings on stdin, no_log, no argument expansion" \
  "tpy 'x=t[\"The realm\"]; c=x[\"ansible.builtin.command\"]; assert \"stdin\" in c and x[\"no_log\"] is True and c[\"expand_argument_vars\"] is False
assert \"client\" not in c[\"argv\"] and \"pve_sso_client_key\" in c[\"stdin\"]'"
check "realm task: check mode runs the script with --check" "tpy 'assert \"--check\" in t[\"The realm\"][\"ansible.builtin.command\"][\"argv\"]'"
check "the client key is read with no_log" "tpy 'assert t[\"Read the client secret from Vault\"][\"no_log\"] is True'"
c=ansible/roles/pve_sso/tasks/ceph.yml
# shellcheck disable=SC2329  # called through check's eval
cpy() { python3 -c "import yaml; t={x['name']: x for x in yaml.safe_load(open('$c'))}; $1"; }
check "Ceph: a member's password goes from openssl to a temp file only, never a command line or the log" \
  "cpy 'x=t[\"Ceph | a dashboard user for each member\"][\"ansible.builtin.shell\"][\"cmd\"]
assert \"mktemp\" in x and \"trap\" in x and \"openssl rand\" in x and \"-i \\\"\$f\\\"\" in x and \">/dev/null\" in x'"
check "Ceph: members are read from Authentik on the identity VM" \
  "cpy 'assert t[\"Ceph | the group\x27s members, from Authentik\"][\"delegate_to\"]==\"{{ pve_sso_identity_host }}\"'"
check "Ceph: nothing changes in check mode" \
  "cpy 'n=[\"Ceph | restart the manager so the dashboard sees the library\",\"Ceph | point the dashboard at Authentik\",\"Ceph | a dashboard user for each member\",\"Ceph | SSO on\"]
assert all(\"not ansible_check_mode\" in str(t[k][\"when\"]) for k in n)'"
check "pve-realm.pl has nothing Jinja would read as a template" \
  "! grep -qE '\{%|\{#|\{\{|%\}|#\}|\}\}' ansible/roles/pve_sso/files/pve-realm.pl"
check "pve-realm.pl never prints the client key" \
  "! grep -nE 'print.*client-key|print.*\\\$want->\{.client-key.\}' ansible/roles/pve_sso/files/pve-realm.pl"
check "cluster.yml: role pve_sso on the main host, hosts.yml on the members, tag sso" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/cluster.yml\"))
m=[x for x in p if any(r.get(\"role\")==\"pve_sso\" for r in x.get(\"roles\",[]))]; assert len(m)==1 and m[0][\"hosts\"]==\"proxmox\"
s=[x for x in p if x[\"hosts\"]==\"cluster_members\" and any(\"include_role\" in str(k) for t in x.get(\"tasks\",[]) for k in t)]
i=s[-1][\"tasks\"][0][\"ansible.builtin.include_role\"]; assert i[\"name\"]==\"pve_sso\" and i[\"tasks_from\"]==\"hosts.yml\" and i[\"apply\"][\"tags\"]==[\"sso\"]'"

[ "$fail" -eq 0 ] && echo "PASS: pve_sso"
exit "$fail"
