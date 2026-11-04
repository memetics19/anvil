#!/usr/bin/env bash
# Every container image a role pulls is pinned to a digest (name:tag@sha256:...), so a pull
# never brings in something new by surprise and the nightly Trivy scan sees exactly what
# runs. Left out: the images built here from pinned bases (caddy, iptv-streams) and Pulse,
# whose updater writes the digest it pulls (pulse-update). Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
built_here='^(caddy_image|iptv_streams_image|pulse_image|[a-z_]+_caddy_image):'

# Image variables in role defaults.
while IFS=: read -r file _ line; do
  name=${line%%:*}
  grep -qE "$built_here" <<<"$line" && continue
  if grep -q '@sha256:[0-9a-f]\{64\}' <<<"$line"; then echo "ok   $name"; else echo "FAIL $name is not pinned to a digest ($file)"; fail=1; fi
done < <(grep -rnE '^[a-z_]+_image: ' ansible/roles/*/defaults/main.yml)

# Literal images in templates (a variable is checked above).
while IFS=: read -r file _ line; do
  echo "FAIL a literal image without a digest in $file: ${line#"${line%%[![:space:]]*}"}"
  fail=1
done < <(grep -rnE '^\s+image: [a-z]' ansible/roles/*/templates/ | grep -v '@sha256:')

[ "$fail" = 0 ] && echo "PASS: images pinned"
exit "$fail"
