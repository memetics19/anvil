#!/usr/bin/env bash
# Docker publishes ports past ufw, so every published port in a compose template must name
# the address it listens on (a host's lab address, or 127.0.0.1), never all interfaces.
# See ansible/roles/host_firewall/defaults/main.yml.
# Jinja control lines ({% ... %}, {# ... #}), comments and blank lines inside a ports: list
# are skipped, so ports inside {% if %} and {% for %} blocks are checked too.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# Prints each published port in file $1 that does not name its address.
scan() {
  awk '
    /^[[:space:]]*ports:/ { p = 1; next }
    p && /^[[:space:]]*(#|\{%|\{#|$)/ { next }
    p && /^[[:space:]]*- / {
      v = $0; sub(/^[[:space:]]*- */, "", v); gsub(/"/, "", v)
      # address:host:container, where the address is a template, 127.0.0.1 or an IPv4
      if (v !~ /^(\{\{[^}]+\}\}|127\.0\.0\.1|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[^:]+:/) print $0
      next
    }
    p { p = 0 }
  ' "$1"
}

bad=0

# Self-test: bare ports inside Jinja blocks and after a blank line are caught, and the list
# still ends at the next key.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/docker-compose.yaml.j2" <<'FIXTURE'
services:
  web:
    ports:
      - "{{ ip }}:443:443"
{% if web_published | bool %}
      - "8080:8080"
{% endif %}
{% for ip in listen_ips %}
      - "{{ ip }}:53:53/udp"

      - "9090:9090"
{% endfor %}
    volumes:
      - ./data:/data
FIXTURE
got=$(scan "$tmp/docker-compose.yaml.j2")
want='      - "8080:8080"
      - "9090:9090"'
if [ "$got" != "$want" ]; then
  echo "FAIL self-test: the scanner must report exactly the two bare ports in the fixture"
  echo "  got:  $got"
  echo "  want: $want"
  bad=1
fi

while IFS= read -r f; do
  while IFS= read -r line; do
    echo "FAIL $f: $line (publish on an address, for example \"{{ site.hosts[inventory_hostname].ip }}:8080:8080\")"
    bad=1
  done < <(scan "$f")
done < <(git ls-files 'ansible/roles/*/templates/*compose*' 'ansible/roles/*/files/*compose*')

if [ "$bad" = 0 ]; then echo "PASS: every published port names its address"; else echo "FAIL: published ports"; fi
exit "$bad"
