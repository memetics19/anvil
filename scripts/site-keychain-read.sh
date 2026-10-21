#!/usr/bin/env bash
# Print the Keychain bootstrap copy of the site dict (service homelab, account
# site-bootstrap) as stored by scripts/site-to-keychain.sh: YAML or JSON with a top-level
# site dict. Accepts every stored form:
#   gz64:<base64>  gzip, then base64 (site-to-keychain.sh writes this: `security -i` reads
#                  lines of under 4000 bytes, which the plain dict outgrew)
#   all hex        `security -w` prints a multi-line value hex-encoded
#   anything else  the value as it is
# Exits 1 (printing nothing) when the item is missing or does not decode.
set -euo pipefail
{ set +x; } 2>/dev/null

v="$(security find-generic-password -s homelab -a site-bootstrap -w 2>/dev/null)" || exit 1
case $v in
  gz64:*) printf '%s' "${v#gz64:}" | base64 -d 2>/dev/null | gunzip -c 2>/dev/null ;;
  *[!0-9a-f]*) printf '%s' "$v" ;;
  *) printf '%s' "$v" | xxd -r -p ;;
esac
