#!/usr/bin/env bash
# Drop one inventory host's stored SSH host key after a deliberate rebuild, so the next run
# records the new one. Called by make forget-host HOST=<name>, with scripts/env.sh sourced.
#   usage: scripts/forget-host.sh <inventory host>
# The name must be exactly one inventory host. A group, a pattern or an unknown name is
# refused, and so is a host that Ansible does not reach over SSH.
# Where the key is:
#   an SSH host   ~/.ssh/known_hosts (FORGET_HOST_KNOWN_HOSTS overrides it), under its
#                 ansible_host
#   the switch    build/switch/known_hosts, the file scripts/switch-cli.sh reads
#                 (SWITCH_KNOWN_HOSTS overrides it), under site.network.switch_ip
# It prints the keys it removed, or says that no key was stored. ssh-keygen errors are not
# hidden. Exit codes: 0 removed or nothing stored, 1 refused or failed, 2 usage.
set -euo pipefail

die() { echo "forget-host: $*" >&2; exit 1; }
[ $# -eq 1 ] || { echo "usage: $0 <inventory host>" >&2; exit 2; }
host=$1
case "$host" in
  '' | *[!A-Za-z0-9._-]*) die "'$host' is not a host name. Name one inventory host." ;;
esac
root=$(cd "$(dirname "$0")/.." && pwd)

# One debug result per matched host. msg: "<kind> <address>", kind is switch for the
# network_switches group, else the host's connection.
msg='{{ "switch" if "network_switches" in group_names else ansible_connection | default("ssh") }}'
msg+=' {{ site.network.switch_ip if "network_switches" in group_names else ansible_host }}'
rc=0
json=$(cd "$root/ansible" && ANSIBLE_LOAD_CALLBACK_PLUGINS=1 ANSIBLE_STDOUT_CALLBACK=ansible.posix.json \
  ansible "$host" -m ansible.builtin.debug -a "$(jq -cn --arg m "$msg" '{msg: $m}')" 2>/dev/null) || rc=$?
rows=$(jq -r '[.plays[]?.tasks[]?.hosts // {} | to_entries[]] | .[] |
  "\(.key) \(if .value.failed then "failed" else "ok" end) \(.value.msg)"' <<<"$json" 2>/dev/null) ||
  die "ansible gave no result for $host (exit $rc)"

n=$(grep -c . <<<"$rows" || true)
[ "$n" -gt 0 ] || die "$host is not a host in the inventory"
[ "$n" -eq 1 ] || die "$host matches $n hosts. Name one host, not a group."
read -r name status kind addr <<<"$rows"
[ "$name" = "$host" ] || die "$host is a group or a pattern (it matches $name). Name the host itself."
[ "$status" = ok ] || die "could not resolve the address of $host: $kind $addr"
[ -n "${addr:-}" ] || die "no address for $host in the inventory"

case "$kind" in
  switch) file=${SWITCH_KNOWN_HOSTS:-$root/build/switch/known_hosts} ;;
  ssh | smart) file=${FORGET_HOST_KNOWN_HOSTS:-$HOME/.ssh/known_hosts} ;;
  *) die "$host connects with $kind, not SSH. It has no host key to forget." ;;
esac

if [ ! -e "$file" ]; then
  echo "forget-host: no key stored for $host ($addr). $file does not exist."
  exit 0
fi
rc=0
found=$(ssh-keygen -l -F "$addr" -f "$file") || rc=$?
case "$rc" in
  0) ;;
  1) echo "forget-host: no key stored for $host ($addr) in $file."; exit 0 ;;
  *) die "ssh-keygen could not read $file (exit $rc)" ;;
esac

ssh-keygen -R "$addr" -f "$file" >/dev/null || die "ssh-keygen could not update $file"
rc=0
ssh-keygen -F "$addr" -f "$file" >/dev/null || rc=$?
[ "$rc" = 1 ] || die "a key of $host ($addr) is still in $file"

echo "forget-host: removed from $file:"
sed -n 's/^\([^#]\)/  \1/p' <<<"$found"
echo "forget-host: the next run records the new key of $host."
