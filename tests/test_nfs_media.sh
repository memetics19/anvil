#!/usr/bin/env bash
# NFS for the media library (role nfs_media): the exports are read-only, squashed and only
# for the listed clients; only NFSv4; the guard drops NFS and rpcbind from anywhere but the
# listed clients on the NetBird interface, and parses (nft -c, Linux with sudo only).
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: NFS templates
  hosts: localhost
  gather_facts: false
  vars:
    site: {nfs: {clients: [100.64.0.7, 100.64.0.9]}}
  vars_files:
    - $PWD/ansible/roles/nfs_media/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/nfs_media/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0644"
      loop: [media.exports, nfs.conf, nfs-guard.nft]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi

e=$tmp/media.exports
check "only movies and tv are exported, not downloads" \
  "[ \"\$(grep -v '^#' '$e' | grep -v '^\$' | awk '{print \$1}' | tr '\n' ' ')\" = '/home/ubuntu/media/movies /home/ubuntu/media/tv ' ] && ! grep -q downloads '$e'"
check "each export names only the listed clients" \
  "[ \$(grep -o '100\.64\.0\.[0-9]*(' '$e' | wc -l) -eq 4 ] && ! grep -q '\*' '$e'"
check "every client is read-only and squashed" \
  "[ \$(grep -o '(ro,all_squash,anonuid=1000,anongid=1000,no_subtree_check,sec=sys,secure)' '$e' | wc -l) -eq 4 ] && ! grep -q '(rw' '$e' && ! grep -q no_root_squash '$e'"
check "NFSv4 only, TCP only" "grep -qx 'vers3=n' '$tmp/nfs.conf' && grep -qx 'udp=n' '$tmp/nfs.conf' && grep -qx 'vers4.0=n' '$tmp/nfs.conf'"
g=$tmp/nfs-guard.nft
check "guard: NFS and rpcbind dropped off the NetBird interface" "grep -q 'th dport { 111, 2049 } iifname != \"wt0\" iifname != \"lo\" counter drop' '$g'"
check "guard: on NetBird, only the listed clients" "grep -q 'iifname \"wt0\" ip saddr != { 100.64.0.7, 100.64.0.9 } counter drop' '$g'"
check "guard: no rpcbind over NetBird at all" "grep -q 'th dport 111 iifname \"wt0\" counter drop' '$g'"
check "guard: replaced in one transaction" "grep -qx 'delete table inet anvil_nfs_guard' '$g'"
if [ "$(uname)" = Linux ] && sudo -n true 2>/dev/null && command -v nft >/dev/null; then
  check "guard: parses (nft -c)" "sudo nft -c -f '$g'"
else
  echo "skip guard: parses (needs Linux, sudo and nft)"
fi

[ "$fail" = 0 ] && echo "PASS: nfs_media" || echo "FAIL: nfs_media"
exit "$fail"
