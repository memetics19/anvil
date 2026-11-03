#!/usr/bin/env bash
# SSH by key only (role ssh_hardening): the drop-in renders, sshd accepts it, it turns
# password and X11 off and keeps root by key, its name sorts before cloud-init's, and every
# VM, the Proxmox host and the other cluster members get it. Renders locally, needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: Render the drop-in
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/roles/ssh_hardening/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/ssh_hardening/templates/00-anvil.conf.j2
        dest: $tmp/00-anvil.conf
        mode: "0644"
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "the drop-in renders"; else bad_ "the drop-in renders"; cat "$tmp/render.log"; exit 1; fi
d=$tmp/00-anvil.conf

check "password login off" "grep -qx 'PasswordAuthentication no' '$d'"
check "keyboard-interactive login off" "grep -qx 'KbdInteractiveAuthentication no' '$d'"
check "root by key only" "grep -qx 'PermitRootLogin prohibit-password' '$d'"
check "X11 forwarding off" "grep -qx 'X11Forwarding no' '$d'"
check "its name sorts before cloud-init's 50-cloudimg-settings.conf" \
  "[ \"\$(printf '%s\n' 50-cloudimg-settings.conf 00-anvil.conf | LC_ALL=C sort | head -1)\" = 00-anvil.conf ]"
if [ -x /usr/sbin/sshd ]; then
  ssh-keygen -q -t ed25519 -N '' -f "$tmp/hostkey"
  check "sshd accepts it" "/usr/sbin/sshd -t -f '$d' -h '$tmp/hostkey'"
fi

# Where it applies: the VM playbook's play covers every VM, host.yml both kinds of node.
vms_hosts=$(awk '/^- name: SSH hardening/{f=1} f && /hosts:/{print $2; exit}' ansible/playbooks/vms.yml)
check "every VM gets it, the enclave's too" \
  "[ '$vms_hosts' = 'guests:vault_servers:apps_servers:vaultwarden_servers:identity_servers:llm_servers' ]"
check "the Proxmox host and the other cluster members get it" \
  "[ \"\$(grep -c 'role: ssh_hardening' ansible/playbooks/host.yml)\" = 2 ]"

[ "$fail" = 0 ] && echo "PASS: ssh hardening"
exit "$fail"
