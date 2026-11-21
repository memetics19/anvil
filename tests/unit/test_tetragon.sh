#!/usr/bin/env bash
# Tetragon (role tetragon) and its Wazuh rules: the release pinned, only policy events exported,
# every policy valid for Tetragon (a selector matches at most 4 values: one more and Tetragon
# refuses to start), audit by default, enforcement switching to Sigkill only where allowed, the
# version check idempotent, and the manager's rules turning events into alerts that page only
# when a process was killed. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/tetragon
py=$(ansible-playbook --version | sed -n 's/^  python version = .*(\(.*\))$/\1/p'); py=${py:-python3}

render() { # render <out dir> <enforce list as YAML>
  mkdir -p "$1"
  cat >"$tmp/play.yml" <<PLAY
- name: Render the policies
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  tasks:
    - ansible.builtin.template: {src: "$r/templates/policies/{{ item }}.yaml.j2", dest: "$1/{{ item }}.yaml", mode: "0644"}
      loop: "{{ tetragon_policies }}"
PLAY
  # As an extra var: vars_files (the defaults) would win over play vars.
  ansible-playbook -i localhost, -c local -e "{\"tetragon_enforce\": $2}" "$tmp/play.yml" >"$tmp/log" 2>&1
}
if render "$tmp/audit" "[]" && render "$tmp/enforce" '["exec-tmp", "kernel-module", "ptrace"]'; then ok "policies render"; else bad_ "policies render"; cat "$tmp/log"; exit 1; fi

# Valid for Tetragon: parses, named anvil-<file>, at most 4 values per Equal/In match.
check "every policy parses, is named after its file, and keeps selectors within 4 values" "'$py' - '$tmp/audit' <<'PY'
import sys, os, yaml
d = sys.argv[1]
for f in os.listdir(d):
    p = yaml.safe_load(open(os.path.join(d, f)))
    assert p['kind'] == 'TracingPolicy' and p['metadata']['name'] == 'anvil-' + f[:-5], f
    for kp in p['spec']['kprobes']:
        for sel in kp.get('selectors', []):
            for m in sel.get('matchArgs', []):
                if m['operator'] in ('Equal', 'In', 'NotEqual', 'NotIn'):
                    assert len(m['values']) <= 4, (f, m)
            assert sel.get('matchActions'), f
PY"
check "audit by default: nothing is killed" "! grep -rq 'Sigkill' '$tmp/audit'"
check "enforcement kills on the enforceable policies" "(for p in exec-tmp kernel-module ptrace; do grep -q 'action: Sigkill' '$tmp/enforce/'\$p.yaml || exit 1; done)"
check "sensitive files only ever report" "! grep -q 'Sigkill' '$tmp/enforce/sensitive-files.yaml' && grep -q 'tetragon_audit_only: \\[sensitive-files\\]' $r/defaults/main.yml && grep -q 'tetragon_enforce | intersect(tetragon_audit_only) | length == 0' $r/tasks/main.yml"

# The release and the service.
check "release pinned by version and checksum" "grep -qx 'tetragon_version: 1.7.1' $r/defaults/main.yml && grep -qE '^tetragon_tarball_sha256: [0-9a-f]{64}$' $r/defaults/main.yml"
check "version check uses tetra (tetragon has no --version), so a rerun changes nothing" "grep -q 'ansible.builtin.command: /usr/local/bin/tetra version' $r/tasks/main.yml && ! grep -q 'tetragon --version' $r/tasks/main.yml"
check "only policy events exported, never every exec and exit" "grep -qx 'tetragon_export_events: \\[PROCESS_KPROBE, PROCESS_TRACEPOINT, PROCESS_LSM\\]' $r/defaults/main.yml && ! grep -q 'PROCESS_EXEC' $r/defaults/main.yml"
check "the apply checks every policy is loaded and enabled" "grep -q \"selectattr('state', 'equalto', 'TP_STATE_ENABLED')\" $r/tasks/main.yml"
check "the Wazuh agent ships the log as JSON" "grep -q '<log_format>json</log_format>' $r/tasks/main.yml"

# Wazuh's rules.
w=ansible/roles/wazuh_server
check "manager rules parse, unique ids, audit below the paging level, a kill pages" "'$py' - $w/files/anvil_tetragon_rules.xml <<'PY'
import sys, xml.etree.ElementTree as ET
root = ET.fromstring('<r>' + open(sys.argv[1]).read().split('-->', 1)[1] + '</r>')
rules = root.findall('.//rule')
ids = [r.get('id') for r in rules]
assert len(ids) == len(set(ids)), ids
lv = {r.get('id'): int(r.get('level')) for r in rules}
assert all(lv[i] < 10 for i in ('100701', '100702', '100703', '100704')), lv
assert lv['100710'] >= 12, lv
PY"
check "rules mounted into the manager" "grep -q 'anvil_tetragon_rules.xml:/wazuh-config-mount/etc/rules/anvil_tetragon_rules.xml:ro' $w/templates/docker-compose.yml.j2 && grep -q 'src: anvil_tetragon_rules.xml' $w/tasks/main.yml"

# Wiring.
check "a play after the Wazuh agents, on the tetragon group" "awk '/^- name: Wazuh agents\$/{a=NR} /^- name: Tetragon\$/{b=NR} END{exit !(a && b && a < b)}' ansible/playbooks/vms.yml && grep -A1 '^- name: Tetragon\$' ansible/playbooks/vms.yml | grep -q 'hosts: tetragon'"
check "the tetragon group is ragnarok, apps, frigate and the assistant" "[ \"\$(awk '/^    tetragon:/{p=1;next} p&&/^    [a-z_]+:/{exit} p' ansible/inventory/hosts.yml | grep -oE '^        [a-z]+:\$' | tr -d ' :' | tr '\\n' ' ')\" = 'ragnarok apps frigate assistant ' ]"

[ "$fail" = 0 ] && echo "PASS: tetragon" || echo "FAIL: tetragon"
exit "$fail"
