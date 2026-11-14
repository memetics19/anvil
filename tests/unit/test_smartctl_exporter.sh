#!/usr/bin/env bash
# smartctl_exporter (role smartctl_exporter): the binary pinned by version and checksum (not
# 0.15.0, which fails every scrape of SAS disks), the unit listens on one address and only
# the allowed clients reach it, root but with only the raw disk capabilities, the RAID disks
# of the main host named with their type, the duplicates on the members left out, and the
# monitoring VM scraping every node. Documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/smartctl_exporter

cat >"$tmp/play.yml" <<PLAY
- name: smartctl_exporter units
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  tasks:
    - name: The main host (RAID disks named)
      ansible.builtin.template: {src: $r/templates/smartctl_exporter.service.j2, dest: $tmp/pve.unit, mode: "0644"}
      vars:
        smartctl_exporter_listen_ip: 192.0.2.10
        smartctl_exporter_devices: ["/dev/bus/0;megaraid,1", "/dev/bus/0;megaraid,2"]
        smartctl_exporter_allow: [192.0.2.132]
    - name: A member (scan, duplicates left out)
      ansible.builtin.template: {src: $r/templates/smartctl_exporter.service.j2, dest: $tmp/member.unit, mode: "0644"}
      vars:
        smartctl_exporter_listen_ip: 198.51.100.40
        smartctl_exporter_device_exclude: "^bus_"
        smartctl_exporter_allow: [192.0.2.132, 198.51.100.250]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1; then ok "units render"; else bad_ "units render"; cat "$tmp/log"; exit 1; fi
p=$tmp/pve.unit m=$tmp/member.unit d=$r/defaults/main.yml

check "pinned version and checksum" "grep -qx 'smartctl_exporter_version: 0.14.0' '$d' && grep -qE '^smartctl_exporter_tarball_sha256: [0-9a-f]{64}$' '$d'"
check "listens on one address" "grep -q -- '--web.listen-address=192.0.2.10:9633' '$p' && grep -q -- '--web.listen-address=198.51.100.40:9633' '$m'"
check "only the allowed clients" "grep -qx 'IPAddressDeny=any' '$p' && grep -qx 'IPAddressAllow=localhost 192.0.2.10 192.0.2.132' '$p' && grep -qx 'IPAddressAllow=localhost 198.51.100.40 192.0.2.132 198.51.100.250' '$m'"
check "only raw disk capabilities" "grep -qx 'CapabilityBoundingSet=CAP_SYS_RAWIO CAP_SYS_ADMIN CAP_DAC_OVERRIDE' '$p' && grep -qx 'NoNewPrivileges=true' '$p' && grep -qx 'ProtectSystem=strict' '$p'"
check "RAID disks named with their type" "grep -q -- '--smartctl.device=/dev/bus/0;megaraid,1' '$p' && grep -q -- '--smartctl.device=/dev/bus/0;megaraid,2' '$p' && ! grep -q 'device-exclude' '$p'"
check "member scans and leaves the duplicates out" "grep -q -- '--smartctl.device-exclude=^bus_' '$m' && ! grep -q -- '--smartctl.device=' '$m'"
check "the main host lists its RAID slots" "grep -q 'smartctl_exporter_devices: \\[\"/dev/bus/0;megaraid,1\"' ansible/inventory/group_vars/proxmox.yml"
check "both node plays run it" "[ \$(grep -c 'role: smartctl_exporter' ansible/playbooks/host.yml) = 2 ]"
check "monitoring scrapes it with alerts and a dashboard" "grep -q 'job_name: smart' ansible/roles/monitoring/templates/scrape.yml.j2 && [ -f ansible/roles/monitoring/files/rules/smart.yml ] && [ -f dashboards/smart.jsonnet ]"

[ "$fail" = 0 ] && echo "PASS: smartctl_exporter" || echo "FAIL: smartctl_exporter"
exit "$fail"
