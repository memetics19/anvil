#!/usr/bin/env bash
# Docker publishes ports past ufw, so every published port in a compose template must name
# the address it listens on (a host's lab address, or 127.0.0.1), never all interfaces.
# See ansible/roles/host_firewall/defaults/main.yml.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

bad=0
while IFS= read -r f; do
  while IFS= read -r line; do
    echo "FAIL $f: $line (publish on an address, for example \"{{ site.hosts[inventory_hostname].ip }}:8080:8080\")"
    bad=1
  done < <(awk '
    /^[[:space:]]*ports:/ { p = 1; next }
    p && /^[[:space:]]*#/ { next }
    p && /^[[:space:]]*- / {
      v = $0; sub(/^[[:space:]]*- */, "", v); gsub(/"/, "", v)
      # address:host:container, where the address is a template, 127.0.0.1 or an IPv4
      if (v !~ /^(\{\{[^}]+\}\}|127\.0\.0\.1|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+):[^:]+:/) print $0
      next
    }
    p { p = 0 }
  ' "$f")
done < <(git ls-files 'ansible/roles/*/templates/*compose*' 'ansible/roles/*/files/*compose*')

if [ "$bad" = 0 ]; then echo "PASS: every published port names its address"; else echo "FAIL: published ports"; fi
exit "$bad"
