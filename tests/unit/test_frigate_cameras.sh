#!/usr/bin/env bash
# Frigate's cameras (role frigate_stack, tasks/cameras.yml and templates/config.yml.j2): the
# first camera stays front_door, more cameras from site.frigate_stack.cameras get their own
# camera, go2rtc stream and place in the camera group, on the shared login, and bad entries
# are refused. Renders locally with documentation addresses and a made-up login.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v ansible-playbook >/dev/null || { echo "FAIL ansible-playbook not found"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }

# render <more cameras as YAML flow> <out file>
render() {
  cat >"$tmp/play.yml" <<PLAY
- name: Frigate cameras
  hosts: localhost
  gather_facts: false
  vars:
    site: {domain: example.com, frigate_stack: {genai_ollama_ip: 192.0.2.50, cameras: $1}}
    frigate_stack_more_cameras: "{{ site.frigate_stack.cameras }}"
    frigate_stack_camera_group: Home
    frigate_stack_vault_frigate_path: homelab/frigate/frigate
    frigate_stack_camera_user: viewer
    frigate_stack_camera_password: "p%40ss"
    frigate_stack_rtsp_url: rtsp://viewer:p%40ss@192.0.2.10:554/stream1
  tasks:
    - ansible.builtin.include_tasks: $PWD/ansible/roles/frigate_stack/tasks/cameras.yml
    - ansible.builtin.copy:
        content: "{{ lookup('ansible.builtin.template', '$PWD/ansible/roles/frigate_stack/templates/config.yml.j2') }}"
        dest: $2
        mode: "0600"
PLAY
  ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1
}

if render '[{name: driveway, host: 192.0.2.37}]' "$tmp/two.yml"; then ok "two cameras render"; else bad_ "two cameras render"; cat "$tmp/render.log"; exit 1; fi
py() { python3 -c "import yaml,sys; c=yaml.safe_load(open('$1')); $2"; }
check "front_door keeps its stream" \
  "py '$tmp/two.yml' 'assert c[\"cameras\"][\"front_door\"][\"ffmpeg\"][\"inputs\"][0][\"path\"] == \"rtsp://viewer:p%40ss@192.0.2.10:554/stream1\"'"
check "the second camera is on the shared login, port 554 and /stream1 by default" \
  "py '$tmp/two.yml' 'assert c[\"cameras\"][\"driveway\"][\"ffmpeg\"][\"inputs\"][0][\"path\"] == \"rtsp://viewer:p%40ss@192.0.2.37:554/stream1\"'"
check "both detect and record, at 1280x720 by default" \
  "py '$tmp/two.yml' 'd=c[\"cameras\"][\"driveway\"]; assert d[\"ffmpeg\"][\"inputs\"][0][\"roles\"] == [\"detect\", \"record\"] and (d[\"detect\"][\"width\"], d[\"detect\"][\"height\"]) == (1280, 720) and d[\"record\"][\"enabled\"]'"
check "each camera has a go2rtc stream" \
  "py '$tmp/two.yml' 'assert set(c[\"go2rtc\"][\"streams\"]) == {\"front_door\", \"driveway\"}'"
check "the camera group holds both" \
  "py '$tmp/two.yml' 'assert c[\"camera_groups\"][\"Home\"][\"cameras\"] == [\"front_door\", \"driveway\"]'"

if render '[]' "$tmp/one.yml"; then ok "one camera still renders"; else bad_ "one camera still renders"; cat "$tmp/render.log"; fi
check "with no more cameras, only front_door" \
  "py '$tmp/one.yml' 'assert list(c[\"cameras\"]) == [\"front_door\"] and c[\"camera_groups\"][\"Home\"][\"cameras\"] == [\"front_door\"]'"

if render '[{name: dw, host: 192.0.2.37, port: 8554, path: /h264, detect_width: 1920, detect_height: 1080}]' "$tmp/opts.yml"; then
  check "port, path and detection size can be set" \
    "py '$tmp/opts.yml' 'd=c[\"cameras\"][\"dw\"]; assert d[\"ffmpeg\"][\"inputs\"][0][\"path\"].endswith(\"@192.0.2.37:8554/h264\") and d[\"detect\"][\"width\"] == 1920'"
else bad_ "port, path and detection size can be set"; fi

for badcam in '[{name: Drive Way, host: 192.0.2.37}]' '[{name: front_door, host: 192.0.2.37}]' '[{name: driveway}]' '[{name: a, host: 192.0.2.37}, {name: a, host: 192.0.2.38}]'; do
  if render "$badcam" "$tmp/bad.yml"; then bad_ "refused: $badcam"; else ok "refused: $badcam"; fi
done

[ "$fail" = 0 ] && echo "PASS: frigate cameras"
exit "$fail"
