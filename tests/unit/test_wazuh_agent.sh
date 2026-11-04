#!/usr/bin/env bash
# The Wazuh agents (role wazuh_agent): Wazuh's apt key pinned by digest and the repository
# signed by it, the agent held at one version, enrollment by the password from Vault in a file
# only root and wazuh read, on every VM but the enclave's and on both kinds of node. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=ansible/roles/wazuh_agent

check "the apt key is pinned by digest" "grep -qE '^wazuh_agent_gpg_sha256: [0-9a-f]{64}$' $r/defaults/main.yml"
check "the download checks that digest" "grep -q 'checksum: \"sha256:{{ wazuh_agent_gpg_sha256 }}\"' $r/tasks/main.yml"
check "the repository is signed by that key only" "grep -q 'deb \[signed-by={{ wazuh_agent_apt_keyring }}\]' $r/tasks/main.yml"
check "one version, held" \
  "grep -qE '^wazuh_agent_version: [0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' $r/defaults/main.yml && grep -q 'selection: hold' $r/tasks/main.yml"
s=ansible/roles/wazuh_server/defaults/main.yml
if [ -f "$s" ]; then
  check "the agent and server versions match" \
    "[ \"\$(sed -nE 's/^wazuh_agent_version: ([0-9.]+)-.*/\\1/p' $r/defaults/main.yml)\" = \"\$(sed -nE 's/^wazuh_server_version: //p' $s)\" ]"
fi
check "the enrollment password comes from Vault" "grep -q \"secret.enrollment\" $r/tasks/main.yml"
check "its file is root and wazuh only" \
  "grep -A6 'dest: /var/ossec/etc/authd.pass' $r/tasks/main.yml | grep -q 'mode: \"0640\"'"
vms_hosts=$(awk '/^- name: Wazuh agents$/{f=1} f && /hosts:/{print $2; exit}' ansible/playbooks/vms.yml)
check "on the VMs" "[ -n '$vms_hosts' ]"
check "not on the secrets enclave" "! grep -qE 'enclave|vault_servers|vaultwarden_servers' <<<'$vms_hosts'"
check "on the Proxmox host and the other cluster members" \
  "grep -q '^- name: Wazuh agent, Proxmox host' ansible/playbooks/host.yml && grep -q '^- name: Wazuh agent, cluster members' ansible/playbooks/host.yml"

[ "$fail" = 0 ] && echo "PASS: wazuh agent"
exit "$fail"
