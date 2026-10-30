#!/usr/bin/env bash
# NFS for the media library (role nfs_media): the exports are read-only, squashed and only
# for the allowed readers (the operator's lab devices, and NetBird clients when active);
# only NFSv4; the guard admits NFS only from those addresses and parses (nft -c, Linux with
# sudo only). Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# render <site-vars-flow> <extra-facts-flow>
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: NFS templates
  hosts: localhost
  gather_facts: false
  vars:
    site: $1
  vars_files:
    - $PWD/ansible/roles/nfs_media/defaults/main.yml
  tasks:
    - ansible.builtin.set_fact: $2
    - ansible.builtin.set_fact:
        nfs_media_insecure_clients: "{{ nfs_media_lan_clients }}"
        nfs_media_readers: "{{ (nfs_media_lan_clients + (nfs_media_netbird_clients if nfs_media_netbird_active | bool else [])) | unique }}"
    - ansible.builtin.template:
        src: $PWD/ansible/roles/nfs_media/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0644"
      loop: [media.exports, nfs.conf, nfs-guard.nft]
PLAY
  ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1
}

# LAN only (the operator's devices, no NetBird).
render '{admin_sources: [198.51.100.30/32, 198.51.100.31/32]}' '{nfs_media_netbird_active: false}'
if [ $? -eq 0 ]; then ok "templates render (LAN only)"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
e=$tmp/media.exports; g=$tmp/nfs-guard.nft
check "only movies and tv are exported, not downloads" \
  "[ \"\$(grep -v '^#' '$e' | grep -v '^\$' | awk '{print \$1}' | tr '\n' ' ')\" = '/home/ubuntu/media/movies /home/ubuntu/media/tv ' ] && ! grep -q downloads '$e'"
check "the lab devices are exported, read-only, squashed, insecure (for VLC's high ports)" \
  "[ \$(grep -o '198[.]51[.]100[.]3[01]/32([^)]*,insecure)' '$e' | wc -l) -eq 4 ]"
check "never writable, never a wildcard, never no_root_squash" "! grep -qE '\(rw|\*|no_root_squash' '$e'"
check "guard: NFS ports accepted only from the lab devices" \
  "grep -q 'th dport { 111, 2049, 20048, 32765 } ip saddr { 198.51.100.30/32, 198.51.100.31/32 } accept' '$g'"
check "guard: every other NFS/rpcbind/mountd/statd packet dropped (not loopback)" \
  "grep -q 'th dport { 111, 2049, 20048, 32765 } iifname != \"lo\" counter drop' '$g'"
check "guard: replaced in one transaction" "grep -qx 'delete table inet anvil_nfs_guard' '$g'"
check "NFSv3 and NFSv4, TCP only, fixed mountd/statd ports" "grep -qx 'vers3=y' '$tmp/nfs.conf' && grep -qx 'udp=n' '$tmp/nfs.conf' && grep -qx 'port=20048' '$tmp/nfs.conf'"

# LAN plus NetBird (both active): both sets of readers, NetBird secure.
render '{admin_sources: [198.51.100.30/32], nfs: {clients: [100.64.0.7, 100.64.0.9]}}' '{nfs_media_netbird_active: true}'
check "with NetBird active, both readers are exported" \
  "[ \$(grep -o '198[.]51[.]100[.]30/32([^)]*,insecure)' '$e' | wc -l) -eq 2 ] && [ \$(grep -o '100[.]64[.]0[.][0-9]*([^)]*,secure)' '$e' | wc -l) -eq 4 ]"
check "guard: accepts both the lab devices and the NetBird clients" \
  "grep -q 'ip saddr { 198.51.100.30/32, 100.64.0.7, 100.64.0.9 } accept' '$g'"

if [ "$(uname)" = Linux ] && sudo -n true 2>/dev/null && command -v nft >/dev/null; then
  check "guard: parses (nft -c)" "sudo nft -c -f '$g'"
else
  echo "skip guard: parses (needs Linux, sudo and nft)"
fi

[ "$fail" = 0 ] && echo "PASS: nfs_media" || echo "FAIL: nfs_media"
exit "$fail"
