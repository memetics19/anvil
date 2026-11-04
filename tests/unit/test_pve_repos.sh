#!/usr/bin/env bash
# The Proxmox nodes' apt repositories (role pve_repos): on bookworm the one-line lists as
# before, on trixie the deb822 files of Proxmox's 8 to 9 upgrade guide, never an
# enterprise repository, and both kinds of node get them. Renders locally, needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/pve_repos

for rel in bookworm trixie; do
  mkdir -p "$tmp/$rel"
  cat >"$tmp/play.yml" <<PLAY
- name: Render for $rel
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  tasks:
    - ansible.builtin.template: {src: "$r/templates/{{ item }}.j2", dest: "$tmp/$rel/{{ item }}", mode: "0644"}
      loop: [sources.list, debian.sources, proxmox.sources, ceph.sources]
PLAY
  if ansible-playbook -i localhost, -c local -e "pve_repos_release=$rel" "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "$rel: templates render"; else bad_ "$rel: templates render"; cat "$tmp/render.log"; exit 1; fi
done
b=$tmp/bookworm t=$tmp/trixie

check "bookworm: sources.list keeps Debian, updates and security" \
  "[ \"\$(grep -c '^deb ' $b/sources.list)\" = 3 ] && grep -q 'bookworm-security' $b/sources.list"
check "trixie: sources.list holds no repository" "! grep -q '^deb ' $t/sources.list"
check "trixie: Debian, updates and security in debian.sources" \
  "grep -qx 'Suites: trixie trixie-updates' $t/debian.sources && grep -qx 'Suites: trixie-security' $t/debian.sources"
check "trixie: Debian's keyring named" "[ \"\$(grep -c '^Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg$' $t/debian.sources)\" = 2 ]"
check "trixie: proxmox.sources is the guide's no-subscription entry" \
  "grep -qx 'URIs: http://download.proxmox.com/debian/pve' $t/proxmox.sources &&
   grep -qx 'Suites: trixie' $t/proxmox.sources &&
   grep -qx 'Components: pve-no-subscription' $t/proxmox.sources &&
   grep -qx 'Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg' $t/proxmox.sources"
check "trixie: ceph.sources is Squid without a subscription" \
  "grep -qx 'URIs: http://download.proxmox.com/debian/ceph-squid' $t/ceph.sources && grep -qx 'Components: no-subscription' $t/ceph.sources"
check "no enterprise repository anywhere" "! grep -rq enterprise $tmp/bookworm $tmp/trixie"
check "the enterprise lists are removed" "grep -q 'pve-enterprise.list, pve-enterprise.sources' $r/tasks/main.yml"
check "an unknown release is refused" "grep -q \"pve_repos_release in \\['bookworm', 'trixie'\\]\" $r/tasks/main.yml"
check "both kinds of node get it" "[ \"\$(grep -c 'role: pve_repos' ansible/playbooks/host.yml)\" = 2 ]"
check "ceph_single writes Ceph's repository through it" "grep -q 'tasks_from: ceph' ansible/roles/ceph_single/tasks/cluster.yml"

[ "$fail" = 0 ] && echo "PASS: pve repos"
exit "$fail"
