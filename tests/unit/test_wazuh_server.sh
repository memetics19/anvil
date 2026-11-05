#!/usr/bin/env bash
# The Wazuh server (role wazuh_server): its compose file pins every image, publishes only the
# dashboard and the agent ports on the lab address, takes every password from Vault (none of
# wazuh-docker's defaults survive), agents enroll with a password, the indexer keeps only the
# users the stack needs, and the hash helper keeps a hash that still matches. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/wazuh_server
pw() { python3 -c 'import secrets; print(secrets.token_hex(14) + "aZ7.")'; }
admin=$(pw) kibana=$(pw) api=$(pw) enroll=$(pw)

cat >"$tmp/play.yml" <<PLAY
- name: Render the Wazuh server
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    wazuh_server_secrets: {indexer_admin: "$admin", kibanaserver: "$kibana", api: "$api", enrollment: "$enroll"}
    wazuh_server_hashes: {admin: "\$2b\$12\$adminhash", kibanaserver: "\$2b\$12\$kibanahash"}
  tasks:
    - ansible.builtin.template: {src: "$r/templates/{{ item }}.j2", dest: "$tmp/{{ item }}", mode: "0600"}
      loop: [docker-compose.yml, internal_users.yml, wazuh.yml, wazuh_manager.conf]
PLAY
if ansible-playbook -i localhost, -c local -e wazuh_server_bind_ip=192.0.2.131 "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
c=$tmp/docker-compose.yml

check "every image is pinned to a digest" \
  "[ \"\$(grep -cE '^\s+image: ' $c)\" = 3 ] && ! grep -E '^\s+image: ' $c | grep -v '@sha256:'"
check "published: dashboard and agent ports, on the lab address only" \
  "[ \"\$(grep -cE '^\s+- \"192\.0\.2\.131:(443:5601|1514:1514|1515:1515)\"$' $c)\" = 3 ] &&
   [ \"\$(awk '/ports:/{f=1;next} f&&/^[[:space:]]+- /{n++;next} {f=0} END{print n}' $c)\" = 3 ]"
check "no syslog, API or indexer port outside" "! grep -qE '\"(514|55000|9200)' $c"
check "the passwords come from the secrets" \
  "grep -q 'INDEXER_PASSWORD=$admin' $c && grep -q 'DASHBOARD_PASSWORD=$kibana' $c && grep -q 'API_PASSWORD=$api' $c && grep -q '$api' $tmp/wazuh.yml"
check "every password in the compose file is one of the generated ones" \
  "[ -z \"\$(sed -nE 's/.*PASSWORD=(.*)$/\\1/p' $c | grep -vxF -e '$admin' -e '$kibana' -e '$api')\" ] &&
   [ \"\$(grep -c 'PASSWORD=' $c)\" = 5 ]"
check "the templates hold no password, only variables" \
  "! grep -rhE 'PASSWORD=[^{]|password: \"[^{]|hash: \"[^{]' $r/templates"
check "agents enroll with a password" "grep -q '<use_password>yes</use_password>' $tmp/wazuh_manager.conf && grep -q 'authd.pass' $c"
check "the indexer keeps only admin and kibanaserver" \
  "[ \"\$(grep -cE '^[a-z]+:$' $tmp/internal_users.yml)\" = 2 ] && grep -qx 'admin:' $tmp/internal_users.yml && grep -qx 'kibanaserver:' $tmp/internal_users.yml"
check "the files with passwords are root only" \
  "grep -A12 'name: The stack.s own files with the passwords' $r/tasks/main.yml | grep -q '\"0600\"' && grep -q 'compose_project_mode: \"0600\"' $r/tasks/main.yml"
check "a failed Vault read stops the run, it is never taken for empty" \
  "grep -q 'failed_when: wazuh_server_vault_get.rc not in \[0, 2\]' $r/tasks/main.yml"

if python3 -c 'import bcrypt' 2>/dev/null; then
  printf '%s\n' 'admin:' "  hash: \"$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$admin', bcrypt.gensalt(4)).decode())")\"" >"$tmp/users.yml"
  out=$(printf '{"admin": "%s", "kibanaserver": "%s"}' "$admin" "$kibana" | python3 "$r/files/wazuh-hash.py" "$tmp/users.yml")
  check "hash helper: a matching hash is kept" "[ \"\$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[\"admin\"])' '$out')\" = \"\$(sed -nE 's/  hash: \"(.*)\"/\1/p' $tmp/users.yml)\" ]"
  check "hash helper: a new password gets a new hash" \
    "python3 -c 'import json,sys,bcrypt; h=json.loads(sys.argv[1])[\"kibanaserver\"]; sys.exit(0 if bcrypt.checkpw(sys.argv[2].encode(), h.encode()) else 1)' '$out' '$kibana'"
fi

[ "$fail" = 0 ] && echo "PASS: wazuh server"
exit "$fail"
