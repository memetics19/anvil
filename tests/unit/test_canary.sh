#!/usr/bin/env bash
# The tripwire (role canary): its settings render to valid JSON with every fake service on and
# port scan detection on, alerts go to ntfy with the token in a header and nothing ignored, the
# real SSH guard admits only its sources, and the token is never in the repository. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/canary
token=$(python3 -c 'import secrets; print("tk_" + secrets.token_hex(15))')

cat >"$tmp/play.yml" <<PLAY
- name: Render the canary
  hosts: localhost
  gather_facts: false
  vars_files: [$r/defaults/main.yml]
  vars:
    site:
      admin_sources: [192.0.2.31/32]
      pve: {ip: 192.0.2.10}
      hosts: {netbird: {ip: 192.0.2.115}}
    canary_ntfy: {url: "https://ntfy.example.com/canary", token: "$token"}
  tasks:
    - ansible.builtin.template: {src: "$r/templates/{{ item }}.j2", dest: "$tmp/{{ item }}", mode: "0644"}
      loop: [opencanary.conf, canary-ssh.nft]
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi

c=$tmp/opencanary.conf
py() { python3 -c "import json,sys; c=json.load(open('$c')); $1"; }
check "the settings are valid JSON" "py 'pass'"
check "every fake service is on" \
  "py 'sys.exit(0 if all(c[s + \".enabled\"] for s in [\"ftp\",\"telnet\",\"http\",\"ssh\",\"mysql\",\"mssql\",\"rdp\",\"vnc\",\"redis\",\"tftp\",\"snmp\"]) else 1)'"
check "the fake SSH is not on 22, the real one keeps it" "py 'sys.exit(0 if c[\"ssh.port\"] == 2222 else 1)'"
check "port scans are detected from the kernel log" \
  "py 'sys.exit(0 if c[\"portscan.enabled\"] and c[\"portscan.logfile\"] == \"/var/log/kern.log\" else 1)'"
check "nothing is ignored" "py 'sys.exit(0 if c[\"ip.ignorelist\"] == [] and c[\"logtype.ignorelist\"] == [] else 1)'"
check "alerts go to the ntfy topic" \
  "py 'h=c[\"logger\"][\"kwargs\"][\"handlers\"][\"ntfy\"]; sys.exit(0 if h[\"url\"].endswith(\"/canary\") and h[\"class\"] == \"opencanary.logger.WebhookHandler\" else 1)'"
check "the token is a header, at top priority" \
  "py 'h=c[\"logger\"][\"kwargs\"][\"handlers\"][\"ntfy\"][\"headers\"]; sys.exit(0 if h[\"Authorization\"] == \"Bearer $token\" and h[\"Priority\"] == \"5\" else 1)'"
check "the webhook ignores nothing" "py 'sys.exit(0 if \"ignore\" not in c[\"logger\"][\"kwargs\"][\"handlers\"][\"ntfy\"] else 1)'"

g=$tmp/canary-ssh.nft
check "real SSH: the sources are admitted" "grep -q 'tcp dport 22 ip saddr { 192.0.2.31/32, 192.0.2.10, 192.0.2.115 } accept' '$g'"
check "real SSH: anyone else is dropped" "grep -qE '^\s+tcp dport 22 counter drop$' '$g'"
check "real SSH: open connections stay" "grep -q 'ct state established,related accept' '$g'"
# Checking a ruleset needs root: only where sudo asks no password (CI, Linux).
if command -v nft >/dev/null && sudo -n true 2>/dev/null; then
  check "nft accepts the guard" "sudo -n nft -c -f '$g'"
fi
check "the settings file is root only (the token is in it)" \
  "awk '/name: Its settings/{f=1} f && /mode:/{print; exit}' $r/tasks/main.yml | grep -q '\"0600\"'"
check "a changed guard goes in with a rollback" "grep -q 'canary-ssh-rollback' $r/tasks/main.yml"
check "no token in the repository" "! grep -rqE 'tk_[a-z0-9]{29}' ansible docs site"

[ "$fail" = 0 ] && echo "PASS: canary"
exit "$fail"
