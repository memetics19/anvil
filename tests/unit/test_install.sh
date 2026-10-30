#!/usr/bin/env bash
# scripts/install.sh against a fake release on file://: installs the right archive for this
# platform, refuses a checksum mismatch, a missing archive and a tag that is not vX.Y.Z.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rc=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; rc=1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
case $(uname -s) in Darwin) os=darwin ;; *) os=linux ;; esac
case $(uname -m) in x86_64 | amd64) arch=amd64 ;; *) arch=arm64 ;; esac
tag=v9.9.9
rel="$work/releases/download/$tag"
mkdir -p "$rel" "$work/pkg"
printf '#!/bin/sh\necho "anvil 9.9.9"\n' >"$work/pkg/anvil"
chmod +x "$work/pkg/anvil"
archive="anvil_9.9.9_${os}_${arch}.tar.gz"
tar -czf "$rel/$archive" -C "$work/pkg" anvil
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
echo "$(sum "$rel/$archive")  $archive" >"$rel/checksums.txt"

run() { ANVIL_RELEASES="file://$work/releases" ANVIL_VERSION=$tag ANVIL_INSTALL_DIR="$work/bin" sh "$root/scripts/install.sh" >"$work/log" 2>&1; }

if run && [ "$("$work/bin/anvil")" = "anvil 9.9.9" ]; then ok "installs the archive for $os/$arch"; else bad "install"; cat "$work/log"; fi
if grep -q 'next, run: anvil fetch && anvil doctor' "$work/log"; then ok "prints the next step"; else bad "next step"; fi

rm -f "$work/bin/anvil"
echo "0000000000000000000000000000000000000000000000000000000000000000  $archive" >"$rel/checksums.txt"
if ! run && grep -q 'checksum mismatch' "$work/log" && [ ! -e "$work/bin/anvil" ]; then ok "refuses a checksum mismatch"; else bad "checksum mismatch"; fi

rm -f "$rel/$archive"
if ! run && grep -q "cannot download $archive" "$work/log"; then ok "stops when the archive is missing"; else bad "missing archive"; fi

if ANVIL_VERSION=latest sh "$root/scripts/install.sh" >"$work/log" 2>&1; then bad "accepts a tag that is not vX.Y.Z"; else ok "refuses a tag that is not vX.Y.Z"; fi

[ "$rc" = 0 ] && echo "PASS: install script" || echo "FAIL: install script"
exit "$rc"
