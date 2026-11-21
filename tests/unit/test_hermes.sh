#!/usr/bin/env bash
# Hermes on the assistant VM (role hermes): the image is built from a pinned release commit,
# WhatsApp is self-chat with one allowed number and no allow-everyone switch, the Swiggy MCP
# servers are untrusted (writes ask first), nothing is published, the data stays private.
# Uses documentation-range values only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok() { echo "ok   $1"; }
bad() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

r=ansible/roles/hermes
d=$r/defaults/main.yml
c=$r/templates/docker-compose.yaml.j2
t=$r/tasks/main.yml

check "a release tag and its full commit" "grep -qE '^hermes_version: v[0-9]+\.[0-9]+\.[0-9]+$' $d && grep -qE '^hermes_commit: [0-9a-f]{40}$' $d"
check "a moved tag stops the run" "grep -q 'hermes_src.after == hermes_commit' $t"
check "WhatsApp is self-chat by default" "grep -qx 'hermes_whatsapp_mode: self-chat' $d"
check "only the operator's number may talk to it" "grep -q 'WHATSAPP_ALLOWED_USERS' $t && grep -q 'hermes_whatsapp_number' $t"
check "the allow-everyone switches are removed" "grep -q 'GATEWAY_ALLOW_ALL_USERS, WHATSAPP_ALLOW_ALL_USERS, TELEGRAM_ALLOW_ALL_USERS' $t"
check "the number never shows in a log" "awk '/WhatsApp settings in its .env/,/notify:/' $t | grep -q 'no_log: true'"
check "every MCP server is an official one, over OAuth, untrusted (writes ask first)" "python3 -c 'import yaml,sys; m=yaml.safe_load(open(\"$d\"))[\"hermes_mcp_servers\"]; ok=(\"https://mcp.swiggy.com/\", \"https://mcp-server.zomato.com/\"); sys.exit(0 if m and all(v.get(\"trust\")==\"untrusted\" and v.get(\"auth\")==\"oauth\" and v[\"url\"].startswith(ok) for v in m.values()) else 1)'"
check "the container runs the gateway, not the chat CLI" "grep -qF 'command: [\"gateway\", \"run\"]' $c"
check "Telegram: only the operator's user id, the token never in a log" "awk '/Telegram settings in its .env/,/notify:/' $t | grep -q 'TELEGRAM_ALLOWED_USERS' && awk '/Telegram settings in its .env/,/notify:/' $t | grep -q 'no_log: true'"
check "nothing is published" "! grep -q 'ports:' $c"
check "no new privileges, a memory cap" "grep -q 'no-new-privileges:true' $c && grep -q 'mem_limit:' $c"
check "the data folder is private to the container user" "grep -q 'hermes_data_dir }}\", owner: \"{{ hermes_uid }}\", mode: \"0700\"' $t"
check "hermes-cli runs the CLI on the same data and starts the service again" "grep -q 'docker run --rm -it --network host -v {{ hermes_data_dir }}:/opt/data' $r/templates/hermes-cli.j2 && grep -q 'docker start hermes' $r/templates/hermes-cli.j2"
check "a play for the assistant VM" "awk '/^- name: Hermes$/,0' ansible/playbooks/vms.yml | grep -q 'hosts: assistant_servers'"

[ "$fail" = 0 ] && echo "PASS: hermes" || { echo "FAIL: hermes"; exit 1; }
