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
      pve: {ip: 192.0.2.10, hostname: pve}
      hosts:
        frigate: {ip: 192.0.2.114}
        apps: {ip: 192.0.2.121}
        monitoring: {ip: 192.0.2.132}
        vault: {ip: 203.0.113.20}
    monitoring_secrets: {admin_password: "$secret"}
    monitoring_oidc_secret: "$secret"
  tasks:
    - ansible.builtin.template: {src: "$r/templates/{{ item }}.j2", dest: "$tmp/{{ item }}", mode: "0600"}
      loop: [docker-compose.yml, scrape.yml, datasources.yml, dashboards.yml]
PLAY
if ansible-playbook -i "$tmp/inv.yml" -c local -e monitoring_bind_ip=192.0.2.132 "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
c=$tmp/docker-compose.yml s=$tmp/scrape.yml

check "every image is pinned to a digest" \
  "[ \"\$(grep -cE '^\s+image: ' $c)\" = 3 ] && ! grep -E '^\s+image: ' $c | grep -v '@sha256:'"
check "only Grafana is published, on the lab address" \
  "[ \"\$(grep -cE '^\s+- \"[0-9.]+:[0-9]+:[0-9]+\"' $c)\" = 1 ] && grep -q '\"192.0.2.132:3000:3000\"' $c"
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
check "dashboards cannot be changed in the UI" "grep -q 'allowUiUpdates: false' $tmp/dashboards.yml"

for d in "$r"/files/dashboards/*.json; do
  n=$(basename "$d")
  check "$n: built from Grafonnet ($(basename "$n" .json).jsonnet)" "[ -f 'dashboards/$(basename "$n" .json).jsonnet' ]"
  check "$n: valid JSON with a uid and a title" "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d[\"uid\"] and d[\"title\"]' '$d'"
  check "$n: every panel queries the provisioned data source" \
    "python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert all(t[\"datasource\"][\"uid\"]==\"victoriametrics\" for p in d[\"panels\"] for t in p.get(\"targets\",[]))' '$d'"
done

check "Authentik makes Grafana's client secret" "grep -q 'grafana_client_secret\]' ansible/roles/authentik/defaults/main.yml"
check "Authentik's Grafana app admits only the single sign-on group" \
  "awk '/id: grafana-app/{f=1} f&&/group: !KeyOf sso-group/{print; exit}' ansible/roles/authentik/templates/anvil-sso.yaml.j2 | grep -q sso-group"

[ "$fail" = 0 ] && echo "PASS: monitoring"
exit "$fail"
