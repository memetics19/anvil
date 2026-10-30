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
# Two sources (anvil with checksums.txt, pulse with SHA256SUMS and three packages).
# Needs ansible-playbook, git, gpg, gpgv, dpkg-deb, apt-ftparchive and apt-get (CI: Ubuntu).
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
skip() { if [ -n "${CI:-}" ]; then echo "FAIL: cannot run in CI: $1"; exit 1; fi; echo "SKIP: $1"; exit 0; }

for c in ansible-playbook git gpg gpgv dpkg-deb apt-ftparchive apt-get; do
  command -v "$c" >/dev/null || skip "$c missing (Debian or Ubuntu tools)"
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
    inventory_hostname: netbird
    site: {hosts: {netbird: {ip: 192.0.2.5}}}
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
check "the index page names no host and lists both sources" "! grep -qiE 'shreeda|\\.xyz' '$tmp/index.html' && grep -q 'memetics19/pulse' '$tmp/index.html'"
check "publish.conf lists both sources" "grep -q 'memetics19/pulse|pulse pulse-agent pulse-cli|SHA256SUMS' '$tmp/publish.conf'"

# --- a key, an upstream repo and its releases ----------------------------------------------------------
mkdir -p "$GNUPGHOME" && chmod 700 "$GNUPGHOME"
gpg --batch --quiet --passphrase '' --quick-gen-key 'test <t@example.com>' rsa2048 sign 1d
gh="$tmp/gh"
newrepo() { # newrepo <owner/repo>: a git repository under the fake GitHub
  git init -q -b main "$gh/$1"
  git -C "$gh/$1" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q --allow-empty -m init
}
mkdeb() { # mkdeb <package> <version> <arch> <dir>
  local d="$tmp/build/$1-$2-$3"
  mkdir -p "$d/DEBIAN" "$d/usr/bin"
  printf '#!/bin/sh\necho %s %s\n' "$1" "$2" >"$d/usr/bin/$1"
  chmod 755 "$d/usr/bin/$1"
  printf 'Package: %s\nVersion: %s\nArchitecture: %s\nMaintainer: t <t@example.com>\nDescription: test\n' "$1" "$2" "$3" >"$d/DEBIAN/control"
  dpkg-deb --root-owner-group -b "$d" "$4/${1}_$2_$3.deb" >/dev/null
}
release() { # release <owner/repo> <checksum file> <tag> <package>... (no package: a release without .deb files)
  local repo=$1 sums=$2 tag=$3 v=${3#v} r
  shift 3
  r="$gh/$repo/releases/download/$tag"
  git -C "$gh/$repo" -c tag.gpgsign=false tag "$tag"
  mkdir -p "$r"
  for pkg in "$@"; do mkdeb "$pkg" "$v" amd64 "$r"; mkdeb "$pkg" "$v" arm64 "$r"; done
  printf 'x' >"$r/archive_${v}_linux_amd64.tar.gz"
  (cd "$r" && sha256sum ./* | sed 's#  \./#  #' >"$sums")
}
newrepo memetics19/anvil
release memetics19/anvil checksums.txt v0.1.0 anvil
release memetics19/anvil checksums.txt v0.2.0 anvil
release memetics19/anvil checksums.txt v0.3.0
git -C "$gh/memetics19/anvil" -c tag.gpgsign=false tag v1.0.0-rc.1
newrepo memetics19/pulse
release memetics19/pulse SHA256SUMS v1.0.0
release memetics19/pulse SHA256SUMS v2.1.0 pulse pulse-agent pulse-cli
rel="$gh/memetics19/anvil/releases/download"

dir="$tmp/opt"
mkdir -p "$dir"
cp "$tmp/index.html" "$dir/index.html"
conf="$tmp/test.conf"
sed -e "s#^GITHUB=.*#GITHUB=file://$gh#" \
  -e "s#^DIR=.*#DIR=$dir#" -e "s#^GNUPGHOME=.*#GNUPGHOME=$GNUPGHOME#" "$tmp/publish.conf" >"$conf"
pub() { APT_PUBLISH_CONF="$conf" bash "$tmp/apt-publish.sh" "$@" >"$tmp/out" 2>&1; }
cur() { readlink "$dir/site/current"; }
site() { echo "$dir/site/current"; }

# 1. first run
if pub && grep -q "published 10 packages" "$tmp/out"; then ok "the first run publishes anvil v0.1.0 and v0.2.0 and pulse v2.1.0, three packages, amd64 and arm64"; else bad_ "first run"; cat "$tmp/out"; fi
check "a release without .deb files is skipped from then on" "[ -e '$dir/state/no-deb/memetics19_anvil_v0.3.0_anvil' ] && [ -e '$dir/state/no-deb/memetics19_pulse_v1.0.0_pulse-agent' ]"
check "each package has its own pool directory" "[ -f '$dir/pool/main/p/pulse-agent/pulse-agent_2.1.0_arm64.deb' ] && [ -f '$dir/pool/main/a/anvil/anvil_0.2.0_amd64.deb' ]"
check "an rc tag is ignored" "! grep -q rc <<<\"\$(ls '$dir/pool/main/a/anvil')\""
check "InRelease verifies with the published key" "gpgv --keyring '$(site)/key.gpg' '$(site)/dists/stable/InRelease'"
check "Release.gpg verifies with the published key" "gpgv --keyring '$(site)/key.gpg' '$(site)/dists/stable/Release.gpg' '$(site)/dists/stable/Release'"
check "the key is also published under the first name, anvil.gpg" "cmp -s '$(site)/key.gpg' '$(site)/anvil.gpg' && cmp -s '$(site)/key.asc' '$(site)/anvil.asc'"
check "the armored key and the index page are published" "grep -q 'BEGIN PGP PUBLIC KEY BLOCK' '$(site)/key.asc' && [ -f '$(site)/index.html' ]"
check "the Origin stays anvil, so existing clients keep updating" "grep -qx 'Origin: anvil' '$(site)/dists/stable/Release'"

# apt-get itself, unprivileged, against the published tree
a="$tmp/apt"
mkdir -p "$a/lists/partial" "$a/cache/archives/partial" "$a/etc/sources.list.d" "$a/etc/preferences.d"
echo "deb [signed-by=$(site)/key.gpg arch=amd64] file://$(site) stable main" >"$a/etc/sources.list"
aptx() { apt-get -o Dir::Etc="$a/etc" -o Dir::State::Lists="$a/lists" -o Dir::Cache="$a/cache" \
  -o Dir::State::status=/dev/null -o Debug::NoLocking=1 -o APT::Architecture=amd64 "$@"; }
# apt_sim <line start> <packages...>: a simulated install, captured whole and then searched.
# Piped straight into grep -q, grep stopped at the first match while apt-get was still
# writing, apt-get died of SIGPIPE, and pipefail turned that into a random failure.
# shellcheck disable=SC2329  # called through check's eval
apt_sim() { local want=$1 out; shift; out=$(aptx -s install "$@" 2>/dev/null) && grep -qF -- "$want" <<<"$out"; }
if aptx update >"$tmp/apt.log" 2>&1 && ! grep -qiE 'NO_PUBKEY|not signed|BADSIG|W: |E: ' "$tmp/apt.log"; then
  ok "apt-get update accepts the signed repository"
else bad_ "apt-get update"; cat "$tmp/apt.log"; fi
check "apt offers the newest anvil, 0.2.0" "apt_sim 'Inst anvil (0.2.0' anvil"
check "apt offers pulse and pulse-agent, 2.1.0" "apt_sim 'Inst pulse (2.1.0' pulse pulse-agent && apt_sim 'Inst pulse-agent (2.1.0' pulse-agent"

# 2. nothing new, and --check
first=$(cur)
if pub && [ ! -s "$tmp/out" ] && [ "$(cur)" = "$first" ]; then ok "a second run with nothing new changes nothing"; else bad_ "second run"; cat "$tmp/out"; fi
release memetics19/anvil checksums.txt v0.4.0 anvil
if pub --check && grep -q "would fetch anvil_0.4.0_amd64 anvil_0.4.0_arm64" "$tmp/out" && [ "$(cur)" = "$first" ]; then
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
if pub && grep -q "published 12 packages" "$tmp/out" && [ "$(cur)" != "$first" ]; then ok "a new release is added and published"; else bad_ "new release"; cat "$tmp/out"; fi
check "the previous tree is kept for clients mid-update" "[ -d '$dir/site/$first' ]"
# sources.list points at site/current, which now names the new tree.
check "apt now offers 0.4.0" "aptx update && apt_sim 'Inst anvil (0.4.0' anvil"

[ "$fail" = 0 ] && echo "PASS: apt repository" || echo "FAIL: apt repository"
exit "$fail"
