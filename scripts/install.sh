#!/bin/sh
# Install the anvil CLI from the latest GitHub Release (or ANVIL_VERSION), checked against
# the release's checksums.txt. Served with the docs site:
#   curl -fsSL https://memetics19.github.io/anvil/install.sh | sh
# Environment:
#   ANVIL_VERSION      a tag such as v0.1.0 (default: the latest release)
#   ANVIL_INSTALL_DIR  where the binary goes (default: /usr/local/bin when writable,
#                      otherwise ~/.local/bin)
#   ANVIL_RELEASES     base URL of the releases (default: GitHub), for tests and mirrors
set -eu

repo=memetics19/anvil
releases=${ANVIL_RELEASES:-https://github.com/$repo/releases}

die() { echo "anvil install: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "needs $1"; }
need curl
need tar

case $(uname -s) in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) die "unsupported OS $(uname -s): use a .deb, .rpm or build from source (docs/install.md)" ;;
esac
case $(uname -m) in
  x86_64 | amd64) arch=amd64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) die "unsupported CPU $(uname -m)" ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
  sha() { sha256sum "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
else
  die "needs sha256sum or shasum"
fi

# The latest tag comes from where /releases/latest redirects to (no API, no rate limit).
tag=${ANVIL_VERSION:-}
if [ -z "$tag" ]; then
  url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$releases/latest") ||
    die "cannot reach $releases"
  tag=${url##*/}
  case $tag in v[0-9]*) ;; *) die "no release is published yet at $releases" ;; esac
fi
case $tag in v[0-9]*) ;; *) die "ANVIL_VERSION must be a tag such as v0.1.0, not '$tag'" ;; esac
version=${tag#v}

archive="anvil_${version}_${os}_${arch}.tar.gz"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT INT TERM
echo "anvil install: $tag for $os/$arch"
curl -fsSL -o "$tmp/$archive" "$releases/download/$tag/$archive" || die "cannot download $archive"
curl -fsSL -o "$tmp/checksums.txt" "$releases/download/$tag/checksums.txt" || die "cannot download checksums.txt"
want=$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/checksums.txt")
[ -n "$want" ] || die "$archive is not in checksums.txt"
[ "$(sha "$tmp/$archive")" = "$want" ] || die "checksum mismatch for $archive"
tar -xzf "$tmp/$archive" -C "$tmp" anvil

dir=${ANVIL_INSTALL_DIR:-}
if [ -z "$dir" ]; then
  if [ -w /usr/local/bin ]; then dir=/usr/local/bin; else dir="$HOME/.local/bin"; fi
fi
mkdir -p "$dir"
install -m 0755 "$tmp/anvil" "$dir/anvil"
echo "anvil install: installed $dir/anvil"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "anvil install: add $dir to your PATH" ;;
esac
echo "anvil install: next, run: anvil fetch && anvil doctor"
