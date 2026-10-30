#!/usr/bin/env bash
# Homepage dashboard (role homepage), run locally with a fixture site dict: site.services ->
# dashboard entries and Homepage's config (services, settings, docker), env file and compose
# file. Checks the grouping, the links (gateway names), widget URLs from the site dict,
# placeholders instead of secrets, no published port, the allowed host, the socket proxy's
# rules; malformed dashboard fields fail the run.
# Uses documentation-range addresses and example.com only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }

# run <services-yaml-flow> -> renders into $tmp; returns the play's rc
run() {
  cat >"$tmp/play.yml" <<PLAY
- name: Homepage test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/inventory/group_vars/all/gateway.yml
  vars:
    inventory_hostname: apps
    site:
      domain: example.com
      gateway: {subdomain: internal}
      email: admin@example.com
      admin_sources: [198.51.100.51/32]
      pve: {ip: 192.0.2.10}
      hosts:
        frigate: {ip: 192.0.2.114}
        ragnarok: {ip: 192.0.2.119}
        vault: {ip: 192.0.2.120}
        apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}
      services: $1
      homepage: ${SITE_HOMEPAGE:-{\}}
    caddy_upstream_cas: {vault: /nonexistent/vault-ca.pem}
  tasks:
    - name: Routes
      ansible.builtin.include_role:
        name: caddy
        tasks_from: services.yml
    - name: Entries
      ansible.builtin.include_role:
        name: homepage
        tasks_from: entries.yml
        public: true
    - name: Fake secret values
      ansible.builtin.set_fact:
        homepage_allowed_host: "{{ (caddy_routes | selectattr('name', 'equalto', homepage_self) | first).fqdn }}"
        homepage_secret_values: "{{ dict(homepage_secret_names | zip(homepage_secret_names | map('regex_replace', '^', 'fake-value-for-'))) }}"
    - name: Render
      ansible.builtin.template:
        src: "$PWD/ansible/roles/homepage/templates/{{ item }}.j2"
        dest: "$tmp/{{ item }}"
        mode: "0600"
      loop: [services.yaml, settings.yaml, widgets.yaml, bookmarks.yaml, docker.yaml, homepage.env, docker-compose.yaml]
PLAY
  rm -f "$tmp"/*.yaml "$tmp/homepage.env"
  # A HOME of its own: the optional background picture is looked up under it.
  mkdir -p "$tmp/home"
  HOME="$tmp/home" ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1
}

# json <file>: the file without its comment lines, as compact JSON (exits non-zero if not JSON)
json() { grep -v '^#' "$tmp/$1" | jq -c .; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

run '[
  {name: pve, host: pve.ip, port: 8006, scheme: https, insecure_upstream: true},
  {name: ceph, host: pve.ip, port: 8443, scheme: https, insecure_upstream: true},
  {name: dns, container: pihole, port: 80, scheme: http, home: /admin/},
  {name: sonarr, host: hosts.ragnarok.ip, port: 8989, scheme: http},
  {name: qbit, host: hosts.ragnarok.ip, port: 8080, scheme: http, host_header: upstream},
  {name: frigate, host: hosts.frigate.ip, port: 8971, scheme: https, insecure_upstream: true},
  {name: gotify, host: hosts.frigate.ip, port: 8080, scheme: http, title: Push, group: Media, icon: mdi-bell, description: Alerts},
  {name: jackett, host: hosts.ragnarok.ip, port: 9117, scheme: http, widget: none},
  {name: newapp, host: hosts.ragnarok.ip, port: 1234, scheme: http},
  {name: home, container: homepage, port: 3000, scheme: http},
  {name: docs, static: docs},
  {name: pass, container: vaultwarden, port: 80, scheme: http, enabled: false}]'
if [ "$?" -eq 0 ] && [ -s "$tmp/services.yaml" ]; then ok "good services render"
else bad_ "good services render"; tail -30 "$tmp/log"; exit 1; fi

s=$(json services.yaml) || { bad_ "services.yaml is JSON (YAML)"; s='[]'; }
check "groups in order, empty ones left out" \
  '[ "$(jq -c "map(keys[0])" <<<"$s")" = "[\"Infrastructure\",\"Media\",\"Home\",\"Other\"]" ]'
# svc <group> <title>: that entry's object
svc() { jq -c --arg g "$1" --arg t "$2" '.[] | select(has($g)) | .[$g][] | select(has($t)) | .[$t]' <<<"$s"; }
check "the dashboard itself is not listed"  '! grep -q "home.internal.example.com" "$tmp/services.yaml"'
check "disabled entry is not listed"        '! grep -qi "vaultwarden\|pass.internal.example.com" "$tmp/services.yaml"'
check "links are the gateway names"         '[ "$(svc Infrastructure Proxmox | jq -r .href)" = "https://pve.internal.example.com" ]'
check "catalog icon and description"        '[ "$(svc Media Sonarr | jq -r .icon)" = "sonarr.png" ]'
check "proxmox widget at the pve upstream"  '[ "$(svc Infrastructure Proxmox | jq -r .widget.url)" = "https://192.0.2.10:8006" ]'
check "proxmox token id, secret placeholder" \
  '[ "$(svc Infrastructure Proxmox | jq -r ".widget.username + \" \" + .widget.password")" = "homepage@pve!homepage {{HOMEPAGE_VAR_PVE_TOKEN}}" ]'
check "ceph status through the Proxmox API" \
  '[ "$(svc Infrastructure Ceph | jq -r .widget.url)" = "https://192.0.2.10:8006/api2/json/cluster/ceph/status" ]'
check "ceph header uses the token placeholder" \
  '[ "$(svc Infrastructure Ceph | jq -r .widget.headers.Authorization)" = "PVEAPIToken=homepage@pve!homepage={{HOMEPAGE_VAR_PVE_TOKEN}}" ]'
check "pihole widget v6 on the container"   '[ "$(svc Infrastructure Pi-hole | jq -c "[.widget.url, .widget.version, .widget.key]")" = "[\"http://pihole:80\",6,\"{{HOMEPAGE_VAR_PIHOLE_KEY}}\"]" ]'
check "pihole container status"            '[ "$(svc Infrastructure Pi-hole | jq -c "[.server, .container]")" = "[\"apps\",\"pihole\"]" ]'
check "upstreams on other VMs: no status"   '[ "$(svc Media Sonarr | jq -c "has(\"server\")")" = false ]'
check "sonarr key placeholder"              '[ "$(svc Media Sonarr | jq -r .widget.key)" = "{{HOMEPAGE_VAR_SONARR_KEY}}" ]'
check "qbittorrent without credentials"     '[ "$(svc Media qBittorrent | jq -c ".widget | keys")" = "[\"type\",\"url\"]" ]'
check "frigate viewer login"                '[ "$(svc Home Frigate | jq -c "[.widget.url, .widget.username, .widget.password]")" = "[\"https://192.0.2.114:8971\",\"homepage\",\"{{HOMEPAGE_VAR_FRIGATE_PASSWORD}}\"]" ]'
check "site hints override the catalog"     '[ "$(svc Media Push | jq -c "[.icon, .description, .href]")" = "[\"mdi-bell\",\"Alerts\",\"https://gotify.internal.example.com\"]" ]'
check "widget: none turns a widget off"     '[ "$(svc Media Jackett | jq -c "has(\"widget\")")" = false ]'
check "static site: a tile, no widget, no status" \
  '[ "$(svc Infrastructure Docs | jq -c "[.href, has(\"widget\"), has(\"container\")]")" = "[\"https://docs.internal.example.com\",false,false]" ]'
check "unknown service goes to Other"       '[ "$(svc Other newapp | jq -r .href)" = "https://newapp.internal.example.com" ]'
check "internal keys stay out (check, service, path)" '! grep -qE "\"(check|service|path)\":" "$tmp/services.yaml"'
check "no fake secret value in the config" '! grep -rq "fake-value" "$tmp/services.yaml" "$tmp/settings.yaml" "$tmp/docker.yaml"'

check "env file: exactly the used secrets" \
  '[ "$(sort "$tmp/homepage.env")" = "$(printf "%s\n" HOMEPAGE_VAR_FRIGATE_PASSWORD=fake-value-for-FRIGATE_PASSWORD HOMEPAGE_VAR_PIHOLE_KEY=fake-value-for-PIHOLE_KEY HOMEPAGE_VAR_PVE_TOKEN=fake-value-for-PVE_TOKEN HOMEPAGE_VAR_SONARR_KEY=fake-value-for-SONARR_KEY | sort)" ]'

st=$(json settings.yaml) || { bad_ "settings.yaml is JSON (YAML)"; st='{}'; }
check "settings: dark slate, blurred cards, clean header, dots, no version" \
  '[ "$(jq -c "[.theme, .color, .cardBlur, .headerStyle, .statusStyle, .hideVersion]" <<<"$st")" = "[\"dark\",\"slate\",\"md\",\"clean\",\"dot\",true]" ]'
check "settings: wide groups 3 columns, others 2" \
  '[ "$(jq -c "[.layout[] | .columns]" <<<"$st")" = "[3,3,2,2]" ]'
check "settings: no background without the picture" '[ "$(jq -c "has(\"background\")" <<<"$st")" = false ]'
check "widgets: date and time only (no search, no weather)" '[ "$(json widgets.yaml | jq -c "map(keys[0])")" = "[\"datetime\"]" ]'
check "settings: layout in group order"     '[ "$(jq -c ".layout | keys_unsorted" <<<"$st")" = "[\"Infrastructure\",\"Media\",\"Home\",\"Other\"]" ]'
check "settings: no update check, no index" '[ "$(jq -c "[.disableUpdateCheck, .disableIndexing]" <<<"$st")" = "[true,true]" ]'
check "docker.yaml: the proxy only"        '[ "$(json docker.yaml)" = "{\"apps\":{\"host\":\"dockerproxy\",\"port\":2375}}" ]'
check "widgets and bookmarks are JSON"     'json widgets.yaml && [ "$(json bookmarks.yaml)" = "[]" ]'

c="$tmp/docker-compose.yaml"
check "compose: images directory read-only"  'grep -q "./images:/app/public/images:ro" "$c"'
check "compose: no published port"         '! grep -qE "^\s+ports:" "$c"'
check "compose: allowed host is the gateway name only" 'grep -qx "      HOMEPAGE_ALLOWED_HOSTS: \"home.internal.example.com\"" "$c"'
check "compose: images pinned by digest"   '[ "$(grep -cE "^    image: [^ ]+:v[0-9.]+@sha256:[0-9a-f]{64}$" "$c")" = 2 ]'
check "compose: memory caps"               'grep -q "mem_limit: 192m" "$c" && grep -q "mem_limit: 32m" "$c"'
check "compose: runs as its own uid"        'grep -q "PUID: \"10003\"" "$c"'
check "compose: config read-only"          'grep -q "./config:/app/config:ro" "$c"'
check "compose: socket read-only, proxy only" '[ "$(grep -c "docker\\.sock:" "$c")" = 1 ] && grep -q "/var/run/docker.sock:/var/run/docker.sock:ro" "$c"'
check "compose: proxy network internal"     'awk "/^  docker_api:/{f=1} f&&/internal: true/{print; exit}" "$c" | grep -q internal'

h=ansible/roles/homepage/files/haproxy.cfg.template
check "proxy: GET only"                    'grep -q "http-request deny unless METH_GET" "$h"'
check "proxy: exactly two allowed paths"  '[ "$(grep -c "http-request allow" "$h")" = 2 ] && grep -q "/containers/json\\$" "$h" && grep -q "/stats\\$" "$h"'
check "proxy: everything else denied"      'grep -qx "    http-request deny" "$h"'

check "no private address in the output"   '! grep -rqE "\b(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+" "$tmp"/*.yaml'

# The optional background picture (a placeholder file in the test HOME) and the weather.
mkdir -p "$tmp/home/homelab-assets" && printf 'placeholder' >"$tmp/home/homelab-assets/homepage-bg.jpg"
SITE_HOMEPAGE='{weather: {latitude: 1.5, longitude: 2.5, label: Here}}' \
  run '[{name: pve, host: pve.ip, port: 8006, scheme: https}, {name: home, container: homepage, port: 3000, scheme: http}]'
rm -rf "$tmp/home/homelab-assets"
st=$(json settings.yaml) || st='{}'
check "background: the picture with its filters" \
  '[ "$(jq -c .background <<<"$st")" = "{\"blur\":\"sm\",\"saturate\":50,\"brightness\":50,\"opacity\":50,\"image\":\"/images/homepage-bg.jpg\"}" ]'
check "weather: Open-Meteo from site.homepage.weather" \
  '[ "$(json widgets.yaml | jq -c ".[1].openmeteo | [.label, .latitude, .longitude, .units]")" = "[\"Here\",1.5,2.5,\"metric\"]" ]'

# Widget results: an error is a warning (the play goes on), or a failure when strict.
widgets() {
  cat >"$tmp/w.yml" <<PLAY
- name: Widget results test
  hosts: localhost
  gather_facts: false
  vars:
    homepage_strict_widgets: $1
    homepage_widget_check:
      results:
        - {item: {name: pve}, stdout: 200 ok}
        - {item: {name: frigate}, stdout: 000 error}
        - {item: {name: sonarr}, stdout: 401 error}
  tasks:
    - name: Results
      ansible.builtin.include_role:
        name: homepage
        tasks_from: widget_results.yml
    - name: Still running
      ansible.builtin.debug:
        msg: AFTER-WIDGETS
PLAY
  ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$tmp/w.yml" >"$tmp/wlog" 2>&1
}
widgets false; rc=$?
if [ "$rc" -eq 0 ] && grep -qF "WARNING: widgets with an error: ['frigate=000 error', 'sonarr=401 error']" "$tmp/wlog" \
   && grep -q AFTER-WIDGETS "$tmp/wlog"; then ok "widget errors warn and the play goes on"
else bad_ "widget errors warn (rc $rc)"; tail -15 "$tmp/wlog"; fi
widgets true; rc=$?
if [ "$rc" -ne 0 ] && grep -qF "widgets with an error: ['frigate=000 error', 'sonarr=401 error']" "$tmp/wlog" \
   && ! grep -q AFTER-WIDGETS "$tmp/wlog"; then ok "homepage_strict_widgets: widget errors fail"
else bad_ "strict widget errors fail (rc $rc)"; fi

reject() {
  run "$2"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'site.services' "$tmp/log"; then ok "rejects $1"
  else bad_ "accepts $1 (rc $rc)"; fi
}
base='{name: home, container: homepage, port: 3000, scheme: http}'
reject "unknown group"            "[$base, {name: a, host: pve.ip, port: 1, scheme: http, group: Nope}]"
reject "unknown widget"           "[$base, {name: a, host: pve.ip, port: 1, scheme: http, widget: nope}]"
reject "unsafe icon"              "[$base, {name: a, host: pve.ip, port: 1, scheme: http, icon: 'http://x/y.png'}]"
reject "unsafe title"             "[$base, {name: a, host: pve.ip, port: 1, scheme: http, title: 'a;b'}]"
reject "same title twice"         "[$base, {name: a, host: pve.ip, port: 1, scheme: http, title: X}, {name: b, host: pve.ip, port: 2, scheme: http, title: X}]"
reject "ceph widget without pve"  "[$base, {name: ceph, host: pve.ip, port: 8443, scheme: https}, {name: pve, host: pve.ip, port: 8006, scheme: https, enabled: false}]"

[ "$fail" -eq 0 ] && echo "PASS: homepage dashboard config"
exit "$fail"
