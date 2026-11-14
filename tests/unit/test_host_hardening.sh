#!/usr/bin/env bash
# Host hardening (role host_hardening): msr is blocked and fwupd's request for it is masked,
# the Proxmox nodes switch rpcbind off and install Debian security updates by themselves
# (that origin only, no reboot), the VMs get only the module block. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=ansible/roles/host_hardening

cat >"$tmp/play.yml" <<PLAY
- name: Render the apt settings
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/$r/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/$r/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0644"
      loop: [52anvil-unattended-upgrades, 21anvil-auto-upgrades]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi
u=$tmp/52anvil-unattended-upgrades

check "msr is the blocked module" "grep -qx 'host_hardening_blocked_modules: \[msr\]' $r/defaults/main.yml"
check "fwupd's boot request is masked before the block" \
  "awk '/Nothing asks for the blocked modules/{a=NR} /The blocked modules never load/{b=NR} END{exit !(a && b && a < b)}' $r/tasks/main.yml"
check "updates: Debian's default origins are cleared first" "grep -qx '#clear Unattended-Upgrade::Origins-Pattern;' '$u'"
check "updates: the Debian-Security origin only" \
  "[ \"\$(grep -c 'origin=' '$u')\" = 1 ] && grep -q 'codename=\${distro_codename}-security,label=Debian-Security' '$u'"
check "updates: never a reboot" "grep -qx 'Unattended-Upgrade::Automatic-Reboot \"false\";' '$u'"
check "updates: every day" "grep -qx 'APT::Periodic::Unattended-Upgrade \"1\";' $tmp/21anvil-auto-upgrades"
check "updates: its file sorts after Debian's 20auto-upgrades" \
  "[ \"\$(printf '%s\n' 20auto-upgrades 21anvil-auto-upgrades | LC_ALL=C sort | tail -1)\" = 21anvil-auto-upgrades ]"

# Where it applies.
check "both kinds of Proxmox node: rpcbind off and automatic updates" \
  "[ \"\$(grep -c 'role: host_hardening' ansible/playbooks/host.yml)\" = 2 ] &&
   grep -q 'host_hardening_rpcbind_off: true' ansible/playbooks/host.yml &&
   grep -q 'host_hardening_auto_security_updates: true' ansible/playbooks/host.yml &&
   grep -q 'vars: \*node_hardening' ansible/playbooks/host.yml"
vms_hosts=$(awk '/^- name: Host hardening/{f=1} f && /hosts:/{print $2; exit}' ansible/playbooks/vms.yml)
check "every VM gets the module block, the enclave's too" \
  "(for g in guests vault_servers apps_servers vaultwarden_servers identity_servers; do grep -qE \"(^|:)\$g(:|\$)\" <<<'$vms_hosts' || exit 1; done)"
check "the VMs keep rpcbind (ragnarok serves NFS)" "grep -qx 'host_hardening_rpcbind_off: false' $r/defaults/main.yml"

[ "$fail" = 0 ] && echo "PASS: host hardening"
exit "$fail"
