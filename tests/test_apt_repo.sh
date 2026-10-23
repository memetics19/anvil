#!/usr/bin/env bash
# The apt repository (role apt_repo): the templates render, and apt-publish, run against a
# local git repo and a local releases directory with real .deb files, a real key and the
# real apt-ftparchive:
#  - every vX.Y.Z release with .deb files lands in the pool, a release without them is
#    skipped from then on, and an rc tag is ignored;
#  - InRelease and Release.gpg verify with the published key, and apt-get itself accepts
#    the repository and offers the newest version;
#  - a second run with nothing new changes nothing, --check changes nothing;
#  - a .deb that does not match checksums.txt stops the run and the live tree stays;
#  - a new release is added and the previous tree is kept for clients mid-update.
# Needs ansible-playbook, git, gpg, gpgv, dpkg-deb, apt-ftparchive and apt-get (CI: Ubuntu).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

for c in ansible-playbook git gpg gpgv dpkg-deb apt-ftparchive apt-get; do
  command -v "$c" >/dev/null || { echo "FAIL $c not found"; exit 1; }
done
tmp=$(mktemp -d)
export GNUPGHOME="$tmp/gnupg"
trap 'gpgconf --kill gpg-agent 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# --- render ----------------------------------------------------------------------------------------
cat >"$tmp/play.yml" <<PLAY
- name: apt repository templates
  hosts: localhost
  gather_facts: false
  vars:
    caddy_image_resolved: anvil/caddy:test
  vars_files:
    - $PWD/ansible/roles/apt_repo/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/apt_repo/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0644"
      loop: [apt-publish.sh, publish.conf, index.html, Caddyfile, compose.yaml]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
check "Caddy refuses anything but GET and HEAD" "grep -q 'not method GET HEAD' '$tmp/Caddyfile' && grep -q 'respond @write 405' '$tmp/Caddyfile'"
check "Caddy is the patched build, not upstream's binary" "grep -q 'image: anvil/caddy:test' '$tmp/compose.yaml'"
check "the site is mounted read-only" "grep -q '/srv/site:ro' '$tmp/compose.yaml'"
check "the index page names no host" "! grep -qiE 'shreeda|\\.xyz' '$tmp/index.html'"

# --- a key, an upstream repo and its releases ----------------------------------------------------------
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'test <t@example.com>' rsa2048 sign 1d
up="$tmp/upstream"
git init -q -b main "$up"
git -C "$up" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
rel="$tmp/releases/download"
mkdeb() { # mkdeb <version> <arch> <dir>
  local d="$tmp/build/anvil-$1-$2"
  mkdir -p "$d/DEBIAN" "$d/usr/bin"
  printf '#!/bin/sh\necho anvil %s\n' "$1" >"$d/usr/bin/anvil"
  chmod 755 "$d/usr/bin/anvil"
  printf 'Package: anvil\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.com>\nDescription: test\n' "$1" "$2" >"$d/DEBIAN/control"
  dpkg-deb --root-owner-group -b "$d" "$3/anvil_$1_$2.deb" >/dev/null
}
release() { # release <tag> [nodeb]
  local v=${1#v}
  git -C "$up" -c tag.gpgsign=false tag "$1"
  mkdir -p "$rel/$1"
  if [ "${2:-}" != nodeb ]; then
    mkdeb "$v" amd64 "$rel/$1"
    mkdeb "$v" arm64 "$rel/$1"
  fi
  printf 'x' >"$rel/$1/anvil_${v}_linux_amd64.tar.gz"
  (cd "$rel/$1" && sha256sum ./* | sed 's#  \./#  #' >checksums.txt)
}
release v0.1.0
release v0.2.0
release v0.3.0 nodeb
git -C "$up" -c tag.gpgsign=false tag v1.0.0-rc.1

dir="$tmp/opt"
mkdir -p "$dir"
cp "$tmp/index.html" "$dir/index.html"
conf="$tmp/test.conf"
sed -e "s#^REPO_URL=.*#REPO_URL=file://$up#" -e "s#^RELEASES=.*#RELEASES=file://$tmp/releases#" \
  -e "s#^DIR=.*#DIR=$dir#" -e "s#^GNUPGHOME=.*#GNUPGHOME=$GNUPGHOME#" "$tmp/publish.conf" >"$conf"
pub() { APT_PUBLISH_CONF="$conf" bash "$tmp/apt-publish.sh" "$@" >"$tmp/out" 2>&1; }
cur() { readlink "$dir/site/current"; }
site() { echo "$dir/site/current"; }

# 1. first run
if pub && grep -q "published 4 packages" "$tmp/out"; then ok "the first run publishes v0.1.0 and v0.2.0 for amd64 and arm64"; else bad_ "first run"; cat "$tmp/out"; fi
check "a release without .deb files is skipped from then on" "[ -e '$dir/state/no-deb-v0.3.0' ]"
check "an rc tag is ignored" "! ls '$dir/pool/main/a/anvil' | grep -q rc"
check "InRelease verifies with the published key" "gpgv --keyring '$(site)/anvil.gpg' '$(site)/dists/stable/InRelease'"
check "Release.gpg verifies with the published key" "gpgv --keyring '$(site)/anvil.gpg' '$(site)/dists/stable/Release.gpg' '$(site)/dists/stable/Release'"
check "the armored key and the index page are published" "grep -q 'BEGIN PGP PUBLIC KEY BLOCK' '$(site)/anvil.asc' && [ -f '$(site)/index.html' ]"

# apt-get itself, unprivileged, against the published tree
a="$tmp/apt"
mkdir -p "$a/lists/partial" "$a/cache/archives/partial" "$a/etc/sources.list.d" "$a/etc/preferences.d"
echo "deb [signed-by=$(site)/anvil.gpg arch=amd64] file://$(site) stable main" >"$a/etc/sources.list"
aptx() { apt-get -o Dir::Etc="$a/etc" -o Dir::State::Lists="$a/lists" -o Dir::Cache="$a/cache" \
  -o Dir::State::status=/dev/null -o Debug::NoLocking=1 -o APT::Architecture=amd64 "$@"; }
if aptx update >"$tmp/apt.log" 2>&1 && ! grep -qiE 'NO_PUBKEY|not signed|BADSIG|W: |E: ' "$tmp/apt.log"; then
  ok "apt-get update accepts the signed repository"
else bad_ "apt-get update"; cat "$tmp/apt.log"; fi
check "apt offers the newest version, 0.2.0" "aptx -s install anvil 2>/dev/null | grep -q 'Inst anvil (0.2.0'"

# 2. nothing new, and --check
first=$(cur)
if pub && [ ! -s "$tmp/out" ] && [ "$(cur)" = "$first" ]; then ok "a second run with nothing new changes nothing"; else bad_ "second run"; cat "$tmp/out"; fi
release v0.4.0
if pub --check && grep -q "would fetch v0.4.0/amd64 v0.4.0/arm64" "$tmp/out" && [ "$(cur)" = "$first" ]; then
  ok "--check reports the new release and changes nothing"; else bad_ "--check"; cat "$tmp/out"; fi

# 3. a tampered .deb
cp "$rel/v0.4.0/anvil_0.4.0_amd64.deb" "$tmp/good.deb"
printf 'tampered' >>"$rel/v0.4.0/anvil_0.4.0_amd64.deb"
if ! pub && grep -q "checksum mismatch for anvil_0.4.0_amd64.deb" "$tmp/out" && [ "$(cur)" = "$first" ] &&
  [ ! -e "$dir/pool/main/a/anvil/anvil_0.4.0_amd64.deb" ]; then
  ok "a .deb that does not match checksums.txt stops the run, the live tree stays"
else bad_ "tampered deb"; cat "$tmp/out"; fi

# 4. the real v0.4.0
cp "$tmp/good.deb" "$rel/v0.4.0/anvil_0.4.0_amd64.deb"
if pub && grep -q "published 6 packages" "$tmp/out" && [ "$(cur)" != "$first" ]; then ok "a new release is added and published"; else bad_ "new release"; cat "$tmp/out"; fi
check "the previous tree is kept for clients mid-update" "[ -d '$dir/site/$first' ]"
# sources.list points at site/current, which now names the new tree.
check "apt now offers 0.4.0" "aptx update && aptx -s install anvil 2>/dev/null | grep -q 'Inst anvil (0.4.0'"

[ "$fail" = 0 ] && echo "PASS: apt repository" || echo "FAIL: apt repository"
exit "$fail"
