#!/usr/bin/env bash
# The media library on ragnarok must survive every run: no file under ansible/ may name
# its path, except the ARR compose template, where it is only a bind-mount source.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

media="/home/ubuntu/""media"
allowed="ansible/roles/arr_stack/templates/docker-compose.yaml.j2"

[ -f "$allowed" ] || { echo "FAIL: $allowed is missing"; exit 1; }

hits=$(grep -rlF --exclude-dir=.ansible --exclude-dir=.collections -- "$media" ansible | grep -vxF "$allowed")
if [ -n "$hits" ]; then
  echo "FAIL: these files name the media path (only $allowed may):"
  printf '%s\n' "$hits" | sed 's/^/  /'
  exit 1
fi

# In the template, every mention is the source of a volume entry ("- <media>/...:/...").
bad=$(grep -nF -- "$media" "$allowed" | grep -vE "^[0-9]+:      - ${media}(/[A-Za-z0-9._-]+)*:/[^:]+$")
if [ -n "$bad" ]; then
  echo "FAIL: $allowed names the media path outside a bind-mount source:"
  printf '%s\n' "$bad"
  exit 1
fi
echo "PASS: the media path appears only as bind-mount sources in $allowed"
