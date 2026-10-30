#!/usr/bin/env bash
# Real roles on a stand-in VM: a privileged Ubuntu 24.04 container with systemd and SSH
# (tests/fixtures/converge/Dockerfile). Ansible reaches it over SSH, as on a real run.
# Each role runs twice. The first run must pass and the second must change nothing. Then
# the result is checked inside the container. Linux with Docker only. The site dict uses
# documentation addresses, plus the container's own address, which exists only during the run.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
skip() { if [ -n "${CI:-}" ]; then echo "FAIL: cannot run in CI: $1"; exit 1; fi; echo "SKIP: $1"; exit 0; }
[ "$(uname)" = Linux ] || skip "needs Linux"
command -v docker >/dev/null && docker info >/dev/null 2>&1 || skip "needs Docker"
command -v ansible-playbook >/dev/null || skip "ansible-playbook missing"

tmp=$(mktemp -d)
name="anvil-converge-$$"
cleanup() { docker rm -f "$name" >/dev/null 2>&1; rm -rf "$tmp"; }
trap cleanup EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
in_vm() { docker exec "$name" "$@"; }

# --- the stand-in VM ------------------------------------------------------------------------
docker build -q -t anvil-converge tests/fixtures/converge >"$tmp/build.log" 2>&1 ||
  { cat "$tmp/build.log"; echo "FAIL the image builds"; exit 1; }
docker run -d --name "$name" --privileged --tmpfs /run --tmpfs /run/lock \
  -p 127.0.0.1::22 anvil-converge >/dev/null || { echo "FAIL the container starts"; exit 1; }

ssh-keygen -q -t ed25519 -N '' -f "$tmp/key"
for _ in $(seq 60); do in_vm systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break; sleep 1; done
in_vm install -d -m 0700 -o ubuntu -g ubuntu /home/ubuntu/.ssh
docker cp "$tmp/key.pub" "$name:/home/ubuntu/.ssh/authorized_keys"
in_vm chown ubuntu:ubuntu /home/ubuntu/.ssh/authorized_keys
port=$(docker port "$name" 22/tcp | head -1 | sed 's/.*://')
vm_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$name")

cat >"$tmp/hosts.yml" <<YAML
all:
  hosts:
    media: {}
    # The gateway VM in the site dict is the same container here.
    apps: {}
  vars:
    ansible_host: 127.0.0.1
    ansible_port: $port
    ansible_user: ubuntu
    ansible_ssh_private_key_file: $tmp/key
    ansible_python_interpreter: /usr/bin/python3
YAML
cat >"$tmp/site.json" <<JSON
{"site": {
  "hosts": {"media": {"ip": "$vm_ip"}, "apps": {"ip": "$vm_ip"}, "netbird": {"ip": "192.0.2.30"}},
  "admin_sources": ["127.0.0.1/32", "192.0.2.10/32"],
  "pve": {"uplink_ip": "192.0.2.1", "uplink_prefix": 24}
}}
JSON

export ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ANSIBLE_ROLES_PATH="$PWD/ansible/roles"
# A known hosts file for this run only: host keys are still checked (accept-new).
export ANSIBLE_SSH_ARGS="-o ControlMaster=auto -o ControlPersist=60s -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$tmp/known_hosts"

# converge <role> <label> [extra vars as JSON]: runs the role twice and checks both runs.
converge() {
  local role=$1 label=$2 vars=${3:-'{}'} run
  cat >"$tmp/play.yml" <<PLAY
- name: Converge $role
  hosts: media
  become: true
  roles:
    - role: $role
PLAY
  for run in first second; do
    if ! ansible-playbook -i "$tmp/hosts.yml" -e "@$tmp/site.json" -e "$vars" "$tmp/play.yml" >"$tmp/$run.log" 2>&1; then
      bad_ "$label: the $run run passes"
      tail -40 "$tmp/$run.log"
      return 1
    fi
  done
  ok "$label: both runs pass"
  local changed
  changed=$(grep -E '^media +:' "$tmp/second.log" | grep -oE 'changed=[0-9]+')
  if [ "$changed" = changed=0 ]; then
    ok "$label: the second run changes nothing"
  else
    bad_ "$label: the second run changes nothing ($changed)"
    grep -E '^changed:' -B2 "$tmp/second.log" | head -30
  fi
}
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# --- node_exporter ----------------------------------------------------------------------------
if converge node_exporter node_exporter; then
  check "node_exporter: the service runs" "in_vm systemctl is-active node_exporter"
  # Saved first, then searched: grep -q in a pipe would cut curl off and fail under pipefail.
  in_vm curl -fsS "http://$vm_ip:9100/metrics" >"$tmp/metrics" 2>/dev/null
  check "node_exporter: metrics are served on the lab address" "grep -q '^node_exporter_build_info' '$tmp/metrics'"
  check "node_exporter: not on every address" "! in_vm curl -fsS -o /dev/null http://127.0.0.1:9100/metrics"
fi

# --- smb_media: read-only guest shares, readers only ------------------------------------------
in_vm install -d -o ubuntu -g ubuntu /home/ubuntu/media/movies /home/ubuntu/media/tv
in_vm sh -c 'echo film >/home/ubuntu/media/movies/film.txt && chown ubuntu:ubuntu /home/ubuntu/media/movies/film.txt'
if converge smb_media smb_media; then
  check "smb_media: Samba runs" "in_vm systemctl is-active smbd"
  check "smb_media: the guard is loaded" "in_vm nft list table inet anvil_smb_guard"
  check "smb_media: a guest reads a file" \
    "in_vm smbclient -N //127.0.0.1/Movies -c 'get film.txt /tmp/got.txt' && in_vm grep -qx film /tmp/got.txt"
  check "smb_media: a guest cannot write" \
    "! in_vm smbclient -N //127.0.0.1/Movies -c 'put /etc/hostname written.txt' || ! in_vm test -e /home/ubuntu/media/movies/written.txt"
  check "smb_media: the library is unchanged" \
    "[ \"\$(in_vm ls /home/ubuntu/media/movies)\" = film.txt ]"
fi

# --- tcp_options_guard: TCP with IP options is dropped, plain TCP is not (CVE-2026-98432) ---
# Loopback traffic passes prerouting too, so the probe runs inside the stand-in VM.
if converge tcp_options_guard tcp_options_guard; then
  docker cp tests/fixtures/tcp_opts_probe.py "$name:/tmp/probe.py"
  in_vm python3 /tmp/probe.py 127.0.0.1 22 >"$tmp/probe" 2>&1
  check "tcp_options_guard: a plain connection works" "grep -qx 'plain: connected' '$tmp/probe'"
  check "tcp_options_guard: a SYN with IP options is dropped" "grep -qx 'with IP options: timed out' '$tmp/probe'"
  check "tcp_options_guard: its counter saw it" \
    "in_vm nft list chain inet anvil_tcp_options_guard prerouting | grep -qE 'counter packets [1-9]'"
fi

# --- port_guard: on, then off -------------------------------------------------------------------
in_vm systemd-run --unit guarded-app python3 -m http.server 18080 --bind 0.0.0.0 >/dev/null
if converge port_guard "port_guard on" '{"port_guard_ports": [18080]}'; then
  check "port_guard: the table is loaded and names the port" \
    "in_vm nft list table inet anvil_port_guard | grep -q 18080"
  check "port_guard: its boot unit is enabled" "in_vm systemctl is-enabled port-guard"
fi
if converge port_guard "port_guard off" '{"port_guard_ports": []}'; then
  check "port_guard off: the table is gone" "! in_vm nft list table inet anvil_port_guard"
  check "port_guard off: its files are gone" \
    "! in_vm test -e /etc/systemd/system/port-guard.service && ! in_vm test -e /etc/anvil/port-guard.nft"
fi

[ "$fail" = 0 ] && echo "PASS: roles converge"
exit "$fail"
