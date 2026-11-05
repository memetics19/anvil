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
admin=$(pw) kibana=$(pw) api=$(pw) enroll=$(pw) reader=$(pw)

cat >"$tmp/play.yml" <<PLAY
- name: Render the Wazuh server
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    wazuh_server_secrets: {indexer_admin: "$admin", kibanaserver: "$kibana", api: "$api", enrollment: "$enroll", grafana_reader: "$reader"}
    wazuh_server_hashes: {admin: "\$2b\$12\$adminhash", kibanaserver: "\$2b\$12\$kibanahash", grafana: "\$2b\$12\$grafanahash"}
  tasks:
    - ansible.builtin.template: {src: "$r/templates/{{ item }}.j2", dest: "$tmp/{{ item }}", mode: "0600"}
      loop: [docker-compose.yml, internal_users.yml, wazuh.yml, wazuh_manager.conf]
      vars: {wazuh_server_alertmanager_url: "http://192.0.2.132:9093/api/v2/alerts"}
    # Without a monitoring VM: no Alertmanager integration.
    - ansible.builtin.template: {src: "$r/templates/wazuh_manager.conf.j2", dest: "$tmp/no-monitoring.conf", mode: "0600"}
      vars: {wazuh_server_alertmanager_url: ""}
PLAY
if ansible-playbook -i localhost, -c local -e wazuh_server_bind_ip=192.0.2.131 "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
c=$tmp/docker-compose.yml

check "every image is pinned to a digest" \
  "[ \"\$(grep -cE '^\s+image: ' $c)\" = 3 ] && ! grep -E '^\s+image: ' $c | grep -v '@sha256:'"
check "published: dashboard, agent ports and the indexer, on the lab address only" \
  "[ \"\$(grep -cE '^\s+- \"192\.0\.2\.131:(443:5601|1514:1514|1515:1515|9200:9200)\"$' $c)\" = 4 ] &&
   [ \"\$(awk '/ports:/{f=1;next} f&&/^[[:space:]]+- /{n++;next} {f=0} END{print n}' $c)\" = 4 ]"
check "no syslog or API port outside" "! grep -qE '\"[0-9.]+:(514|55000):' $c"
check "the indexer answers only the monitoring VM, the gateway, Pulse and the admin sources" \
  "grep -qx 'port_guard_ports: \[443, 9200\]' ansible/inventory/host_vars/wazuh.yml && grep -q 'site.hosts.monitoring.ip' ansible/inventory/host_vars/wazuh.yml"
check "the passwords come from the secrets" \
  "grep -q 'INDEXER_PASSWORD=$admin' $c && grep -q 'DASHBOARD_PASSWORD=$kibana' $c && grep -q 'API_PASSWORD=$api' $c && grep -q '$api' $tmp/wazuh.yml"
check "every password in the compose file is one of the generated ones" \
  "[ -z \"\$(sed -nE 's/.*PASSWORD=(.*)$/\\1/p' $c | grep -vxF -e '$admin' -e '$kibana' -e '$api')\" ] &&
   [ \"\$(grep -c 'PASSWORD=' $c)\" = 5 ]"
check "the templates hold no password, only variables" \
  "! grep -rhE 'PASSWORD=[^{]|password: \"[^{]|hash: \"[^{]' $r/templates"
check "agents enroll with a password" "grep -q '<use_password>yes</use_password>' $tmp/wazuh_manager.conf && grep -q 'authd.pass' $c"
check "the indexer keeps only admin, kibanaserver and grafana" \
  "[ \"\$(grep -cE '^[a-z]+:$' $tmp/internal_users.yml)\" = 3 ] && grep -qx 'admin:' $tmp/internal_users.yml && grep -qx 'kibanaserver:' $tmp/internal_users.yml && grep -qx 'grafana:' $tmp/internal_users.yml"
check "grafana can only read" "awk '/^grafana:/{f=1} f' $tmp/internal_users.yml | grep -q '\"readall\"' && ! awk '/^grafana:/{f=1} f' $tmp/internal_users.yml | grep -q '\"admin\"'"
check "alerts of level 10 and up go to Alertmanager" \
  "grep -q '<name>custom-alertmanager</name>' $tmp/wazuh_manager.conf && grep -q '<hook_url>http://192.0.2.132:9093/api/v2/alerts</hook_url>' $tmp/wazuh_manager.conf && grep -q '<level>10</level>' $tmp/wazuh_manager.conf"
check "no integration without a monitoring VM" "! grep -q custom-alertmanager $tmp/no-monitoring.conf"
check "the integration's files reach the manager" "grep -q '/wazuh-config-mount/integrations/custom-alertmanager:ro' $c"
check "a changed config or integration restarts the manager" "[ \"\$(grep -c 'notify: Restart the Wazuh manager' $r/tasks/main.yml)\" = 2 ]"

# The integration itself, against a stand-in Alertmanager on this machine.
cat >"$tmp/alert.json" <<'JSON'
{"rule": {"level": 13, "id": "5712", "description": "sshd: brute force trying to get access"},
 "agent": {"name": "ragnarok"}, "full_log": "Failed password for invalid user admin"}
JSON
python3 - "$tmp" <<'PY' >"$tmp/posted.json" 2>"$tmp/post.log" &
import http.server, json, sys, threading
tmp = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        print(json.dumps({"path": self.path, "type": self.headers["Content-Type"], "body": json.loads(body)}))
        sys.stdout.flush()
        self.send_response(200); self.end_headers()
        threading.Thread(target=self.server.shutdown).start()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(tmp + "/port", "w").write(str(s.server_port))
s.serve_forever()
PY
for _ in $(seq 50); do [ -s "$tmp/port" ] && break; sleep 0.1; done
python3 "$r/files/custom-alertmanager.py" "$tmp/alert.json" 12 "http://127.0.0.1:$(cat "$tmp/port")/api/v2/alerts" 2>>"$tmp/post.log"
wait
pj() { python3 -c "import json,sys; d=json.load(open('$tmp/posted.json')); $1"; }
check "integration: posts to Alertmanager's alerts API as JSON" "pj 'assert d[\"path\"]==\"/api/v2/alerts\" and d[\"type\"]==\"application/json\"'"
check "integration: WazuhAlert, the agent as host, the rule" \
  "pj 'l=d[\"body\"][0][\"labels\"]; assert (l[\"alertname\"], l[\"host\"], l[\"rule_id\"], l[\"source\"])==(\"WazuhAlert\",\"ragnarok\",\"5712\",\"wazuh\")'"
check "integration: level 13 is critical at 12" "pj 'assert d[\"body\"][0][\"labels\"][\"severity\"]==\"critical\"'"
check "integration: it links to its fix and ends by itself" \
  "pj 'a=d[\"body\"][0]; assert a[\"annotations\"][\"runbook\"].endswith(\"#wazuhalert\") and a[\"endsAt\"] > a[\"startsAt\"]'"
check "integration: level 11 is a warning" \
  "python3 -c 'import importlib.util,sys,datetime; s=importlib.util.spec_from_file_location(\"m\", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); assert m.to_alertmanager({\"rule\":{\"level\":11}}, 12, datetime.datetime.now(datetime.timezone.utc))[0][\"labels\"][\"severity\"]==\"warning\"' '$r/files/custom-alertmanager.py'"
check "the files with passwords are mode 600" \
  "grep -A12 'name: The stack.s own files with the passwords' $r/tasks/main.yml | grep -q '\"0600\"' && grep -q 'compose_project_mode: \"0600\"' $r/tasks/main.yml"
# The indexer and the dashboard run as a non-root user and must read their files.
check "the indexer and dashboard files belong to the container user" \
  "grep -A14 'name: The stack.s own files with the passwords' $r/tasks/main.yml | grep 'internal_users.yml' | grep -q 'wazuh_server_container_uid' && grep -A14 'name: The stack.s own files with the passwords' $r/tasks/main.yml | grep 'wazuh.yml' | grep -q 'wazuh_server_container_uid'"
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
