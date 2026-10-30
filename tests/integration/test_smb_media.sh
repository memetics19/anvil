#!/usr/bin/env bash
# SMB for the media library (role smb_media): read-only guest shares for the readers only,
# the guard admits SMB only from those addresses and parses (nft -c, Linux with sudo only).
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: SMB templates
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: ragnarok
    site:
      admin_sources: [198.51.100.30/32, 198.51.100.31/32]
      pve: {uplink_ip: 192.0.2.250, uplink_prefix: 24}
      hosts: {ragnarok: {home_ip: 192.0.2.247}}
  vars_files:
    - $PWD/ansible/roles/smb_media/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/smb_media/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0644"
      loop: [smb.conf, smb-guard.nft]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/log"; exit 1; fi
c=$tmp/smb.conf; g=$tmp/smb-guard.nft
check "guest access, no password" "grep -q 'map to guest = Bad User' '$c' && grep -q 'guest ok = yes' '$c'"
check "the movies and tv shares, read-only" \
  "grep -q '^\[Movies\]' '$c' && grep -q '^\[TV\]' '$c' && [ \$(grep -c 'read only = yes' '$c') = 2 ] && ! grep -q 'read only = no' '$c'"
check "the home subnet and the operator devices are allowed, others denied" \
  "grep -q 'hosts allow = 198.51.100.30/32 198.51.100.31/32 192.0.2.0/24' '$c' && grep -q 'hosts deny = 0.0.0.0/0' '$c'"
check "SMB2 minimum, no printers" "grep -q 'server min protocol = SMB2' '$c' && grep -q 'load printers = no' '$c'"
check "guard: SMB ports accepted only from the readers" \
  "grep -q 'th dport { 137, 138, 139, 445 } ip saddr { 198.51.100.30/32, 198.51.100.31/32, 192.0.2.0/24 } accept' '$g'"
check "guard: SMB dropped from everyone else (not loopback)" \
  "grep -q 'th dport { 137, 138, 139, 445 } iifname != \"lo\" counter drop' '$g'"
check "guard: replaced in one transaction" "grep -qx 'delete table inet anvil_smb_guard' '$g'"
check "vms.yml: smb_media runs on ragnarok after nfs_media" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/vms.yml\")); r=[x for x in p if x.get(\"hosts\")==\"ragnarok\" and any(e.get(\"role\")==\"smb_media\" for e in x.get(\"roles\",[]))]
assert r, \"no smb_media on ragnarok\"
n=[e[\"role\"] for e in r[0][\"roles\"]]; assert n.index(\"smb_media\") > n.index(\"nfs_media\")'"
if [ "$(uname)" = Linux ] && sudo -n true 2>/dev/null && command -v nft >/dev/null; then
  check "guard: parses (nft -c)" "sudo nft -c -f '$g'"
else
  echo "skip guard: parses (needs Linux, sudo and nft)"
fi

[ "$fail" = 0 ] && echo "PASS: smb_media" || echo "FAIL: smb_media"
exit "$fail"
