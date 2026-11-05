#!/usr/bin/env bash
# The monitoring stack (role monitoring): images pinned, only Grafana published and only on
# the lab address, vmagent scrapes node_exporter on every host of its group and on the
# Proxmox host but nothing in the enclave, Grafana logs in through Authentik and phones
# nowhere, and every dashboard is valid JSON on the provisioned data source. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/monitoring
secret=$(python3 -c 'import secrets; print(secrets.token_hex(16))')

cat >"$tmp/inv.yml" <<'INV'
all:
  children:
    node_exporter:
      hosts: {frigate: {}, apps: {}, monitoring: {}}
    identity_servers:
      hosts: {identity: {}}
    apps_servers:
      hosts: {apps: {}}
    enclave:
      hosts: {vault: {}}
INV
cat >"$tmp/play.yml" <<PLAY
- name: Render the monitoring stack
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    gateway_domain: lab.example.com
    site:
      pve: {ip: 192.0.2.10, hostname: pve, uplink_gw: 198.51.100.1}
      hosts:
        frigate: {ip: 192.0.2.114}
        apps: {ip: 192.0.2.121}
        monitoring: {ip: 192.0.2.132}
        wazuh: {ip: 192.0.2.131}
        vault: {ip: 203.0.113.20}
    monitoring_secrets: {admin_password: "$secret"}
    monitoring_oidc_secret: "$secret"
    monitoring_ntfy: {url: "https://ntfy.example.com/", token: "$secret"}
  tasks:
    - ansible.builtin.template: {src: "$r/templates/{{ item }}.j2", dest: "$tmp/{{ item }}", mode: "0600"}
      loop: [docker-compose.yml, scrape.yml, datasources.yml, dashboards.yml, alertmanager.yml, blackbox.yml]
    # With a Wazuh VM: its data source, read-only, its CA checked.
    - ansible.builtin.template: {src: "$r/templates/datasources.yml.j2", dest: "$tmp/datasources-wazuh.yml", mode: "0600"}
      vars:
        monitoring_wazuh_host: wazuh
        monitoring_wazuh_reader: "$secret"
        monitoring_wazuh_ca_pem: "-----BEGIN CERTIFICATE-----\\nTEST\\n-----END CERTIFICATE-----"
PLAY
if ansible-playbook -i "$tmp/inv.yml" -c local -e monitoring_bind_ip=192.0.2.132 "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
c=$tmp/docker-compose.yml s=$tmp/scrape.yml

# Grafana's server reaches Authentik at the gateway, not through the VM's public resolvers.
check "grafana resolves Authentik's name to the gateway" \
  "grep -A12 '^  grafana:' \$c | grep -q 'auth.lab.example.com:192.0.2.121'"
check "every image is pinned to a digest" \
  "[ \"\$(grep -cE '^\s+image: ' $c)\" = 6 ] && ! grep -E '^\s+image: ' $c | grep -v '@sha256:'"
check "only Grafana and Alertmanager's API are published, on the lab address" \
  "[ \"\$(grep -cE '^\s+- \"[0-9.]+:[0-9]+:[0-9]+\"' $c)\" = 2 ] && grep -q '\"192.0.2.132:3000:3000\"' $c && grep -q '\"192.0.2.132:9093:9093\"' $c"
check "metrics kept 90 days" "grep -q -- '-retentionPeriod=90d' $c"
check "node_exporter on every host of the group" \
  "for a in 192.0.2.114 192.0.2.121 192.0.2.132; do grep -q \"\\\"\$a:9100\\\"\" $s || exit 1; done"
check "and on the Proxmox host" "grep -q '\"192.0.2.10:9100\"' $s"
check "nothing in the secrets enclave" "! grep -q '203.0.113.20' $s"
check "each target is named by its host" "grep -q 'labels: {host: \"frigate\"}' $s"
check "Grafana logs in through Authentik" \
  "grep -q 'GF_AUTH_GENERIC_OAUTH_AUTH_URL: \"https://auth.lab.example.com/application/o/authorize/\"' $c && grep -q 'GF_AUTH_OAUTH_AUTO_LOGIN: \"true\"' $c"
check "Grafana phones nowhere" \
  "grep -q 'GF_ANALYTICS_REPORTING_ENABLED: \"false\"' $c && grep -q 'GF_ANALYTICS_CHECK_FOR_UPDATES: \"false\"' $c && grep -q 'GF_NEWS_NEWS_FEED_ENABLED: \"false\"' $c"
check "no sign-up" "grep -q 'GF_USERS_ALLOW_SIGN_UP: \"false\"' $c"
check "the compose file holding the secrets is root only" "grep -q 'compose_project_mode: \"0600\"' $r/tasks/main.yml"
check "one data source, VictoriaMetrics, uid victoriametrics" "grep -q 'uid: victoriametrics' $tmp/datasources.yml && grep -q 'url: http://victoriametrics:8428' $tmp/datasources.yml"
check "the internet: ping to the router and public resolvers" \
  "grep -q '\"198.51.100.1\"' $s && grep -q 'probe: \"router\", scope: \"local\"' $s && grep -q '\"1.1.1.1\"' $s && grep -q 'scope: \"internet\"' $s"
check "a lookup through Pi-hole" "awk '/job_name: dns/{f=1} f&&/targets/{print; exit}' $s | grep -q '\"192.0.2.121\"'"
check "every probe goes through the blackbox exporter" "[ \"\$(grep -c 'replacement: blackbox:9115' $s)\" = 3 ]"
check "ping needs no raw socket" "grep -q 'net.ipv4.ping_group_range' $c"
check "the OpenSearch plugin at a pinned version" "grep -qE 'GF_PLUGINS_PREINSTALL_SYNC: \"grafana-opensearch-datasource@[0-9]+\.[0-9]+\.[0-9]+\"' $c"
check "no Wazuh data source without a Wazuh VM" "! grep -q 'uid: wazuh' $tmp/datasources.yml"
check "with one: Wazuh's alerts, read-only user, its CA checked" \
  "grep -q 'uid: wazuh' $tmp/datasources-wazuh.yml && grep -q 'basicAuthUser: grafana' $tmp/datasources-wazuh.yml && grep -q 'tlsAuthWithCACert: true' $tmp/datasources-wazuh.yml && grep -q 'url: \"https://192.0.2.131:9200\"' $tmp/datasources-wazuh.yml"
check "the data sources file is for Grafana alone (it holds a password)" "grep -A8 'name: Grafana.s data sources' $r/tasks/main.yml | grep -q 'mode: \"0400\"'"
check "dashboards cannot be changed in the UI" "grep -q 'allowUiUpdates: false' $tmp/dashboards.yml"

for d in "$r"/files/dashboards/*.json; do
  n=$(basename "$d")
  check "$n: built from Grafonnet ($(basename "$n" .json).jsonnet)" "[ -f 'dashboards/$(basename "$n" .json).jsonnet' ]"
  check "$n: valid JSON with a uid and a title" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"uid\"] and d[\"title\"]' '$d'"
  check "$n: every query names a provisioned data source and a refId" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert all(t[\"datasource\"][\"uid\"] in (\"victoriametrics\",\"wazuh\") and t.get(\"refId\") for p in d[\"panels\"] for t in p.get(\"targets\",[]))' '$d'"
done

# --- Alerts ---
a=$tmp/alertmanager.yml
check "critical goes to its own topic at once, at top priority" \
  "grep -q 'https://ntfy.example.com/lab-critical?template=alertmanager&priority=urgent' $a"
check "warnings wait for the morning window" \
  "grep -A6 'receiver: ntfy-warning' $a | grep -q 'active_time_intervals: \[morning\]' && grep -q 'start_time: \"02:30\"' $a"
check "a dead router holds back the internet alerts" "grep -A2 'alertname=\"RouterDown\"' $a | grep -q 'InternetDown|InternetFlaky'"
check "a down host holds back its other alerts" "grep -A3 'inhibit_rules' $a | grep -q 'alertname=\"HostDown\"' && grep -q 'equal: \[host\]' $a"
check "the ntfy token is a file, not in the config" "grep -q 'credentials_file: /etc/alertmanager/ntfy-token' $a && ! grep -q '$secret' $a"
check "the token file is for Alertmanager's user alone" "grep -A6 'name: Alertmanager.s ntfy token' $r/tasks/main.yml | grep -q 'mode: \"0400\"'"
check "rule files are checked by vmalert before they go in" "grep -q -- '-rule=/rules.yml -dryRun' $r/tasks/main.yml"
python3 - "$r/files/rules" docs/monitoring.md <<'PY' || fail=1
import sys, os, re, yaml
rules_dir, doc = sys.argv[1], open(sys.argv[2]).read()
anchors = {re.sub(r'[^a-z0-9-]', '', h.strip().lower().replace(' ', '-')) for h in re.findall(r'(?m)^#{2,3} (.+)$', doc)}
bad = 0
for f in sorted(os.listdir(rules_dir)):
    for g in yaml.safe_load(open(os.path.join(rules_dir, f)))["groups"]:
        for r in g["rules"]:
            n = r["alert"]
            checks = {
                "a level, critical or warning": r.get("labels", {}).get("severity") in ("critical", "warning"),
                "waits before it fires": bool(re.fullmatch(r"\d+[smh]", str(r.get("for", "")))),
                "a summary and a description": bool(r.get("annotations", {}).get("summary")) and bool(r["annotations"].get("description")),
                "links to its section of the docs": r.get("annotations", {}).get("runbook", "").split("#")[-1] in anchors,
            }
            for what, ok in checks.items():
                print(("ok   " if ok else "FAIL ") + f"rule {n}: {what}")
                bad += not ok
sys.exit(1 if bad else 0)
PY

check "Authentik makes Grafana's client secret" "grep -q 'grafana_client_secret\]' ansible/roles/authentik/defaults/main.yml"
check "Authentik's Grafana app admits only the single sign-on group" \
  "awk '/id: grafana-app/{f=1} f&&/group: !KeyOf sso-group/{print; exit}' ansible/roles/authentik/templates/anvil-sso.yaml.j2 | grep -q sso-group"

[ "$fail" = 0 ] && echo "PASS: monitoring"
exit "$fail"
