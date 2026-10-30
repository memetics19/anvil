#!/usr/bin/env bash
# node_exporter (role node_exporter): the unit listens on the host's lab address only, on
# 9100, sandboxed; the binary is pinned by version and checksum; every reachable host is in
# the group and the secrets enclave is not. Documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

cat >"$tmp/play.yml" <<PLAY
- name: node_exporter unit
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: frigate
    site: {hosts: {frigate: {ip: 192.0.2.114}}}
  vars_files:
    - $PWD/ansible/roles/node_exporter/defaults/main.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/node_exporter/templates/node_exporter.service.j2
        dest: $tmp/unit
        mode: "0644"
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1; then ok "unit renders"; else bad_ "unit renders"; cat "$tmp/log"; exit 1; fi
u=$tmp/unit
check "listens on the lab address, port 9100" "grep -q -- '--web.listen-address=192.0.2.114:9100' '$u'"
check "never on every address" "! grep -qE 'listen-address=(:|0\.0\.0\.0)' '$u'"
check "runs as its own user, sandboxed" "grep -qx 'User=node_exporter' '$u' && grep -qx 'NoNewPrivileges=true' '$u' && grep -qx 'ProtectSystem=strict' '$u'"
check "pinned by version and checksum" \
  "python3 -c 'import yaml; d=yaml.safe_load(open(\"ansible/roles/node_exporter/defaults/main.yml\"))
assert d[\"node_exporter_version\"]!=\"1.0.1\" and len(d[\"node_exporter_tarball_sha256\"])==64'"
check "every reachable host is in the group, the secrets enclave is not" \
  "python3 -c 'import yaml; g=yaml.safe_load(open(\"ansible/inventory/hosts.yml\"))
def find(d):
    if isinstance(d,dict):
        if \"node_exporter\" in d and isinstance(d[\"node_exporter\"],dict) and \"hosts\" in d[\"node_exporter\"]: return d[\"node_exporter\"][\"hosts\"]
        for v in d.values():
            r=find(v)
            if r is not None: return r
    return None
h=set(find(g)); assert {\"frigate\",\"ragnarok\",\"netbird\",\"apps\",\"identity\",\"llm\",\"pve\"} <= h, h
assert not ({\"vault\",\"vaultwarden\"} & h)'"

[ "$fail" -eq 0 ] && echo "PASS: node_exporter"
exit "$fail"
