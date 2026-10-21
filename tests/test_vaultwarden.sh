#!/usr/bin/env bash
# Vaultwarden (role vaultwarden), run locally with a fixture site dict:
#  - site.services -> its gateway route (pass.<gateway domain>, websocket), DOMAIN, the
#    compose file (no published port, own uid, read-only, memory cap, sign-ups closed,
#    no SMTP), the env file (the hash only, quoted), the S3 remote, the systemd units, the
#    Caddy network and the dashboard entry (Security); a wrong entry fails the run;
#  - the backup script, run against a fixture data directory with a fake rclone (a local
#    directory as the bucket): a consistent database copy plus attachments, sends, keys and
#    config, encrypted with age; the upload is checked; pruning keeps the newest KEEP of the
#    job's own objects and nothing else is touched.
# Uses documentation-range addresses and example.com only. Needs ansible, jq, sqlite3, age.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
for c in ansible-playbook jq sqlite3 age age-keygen; do
  command -v "$c" >/dev/null || { echo "FAIL $c not found"; exit 1; }
done

out="$tmp/out"
mkdir -p "$out"
# run <services-yaml-flow> [<vault-secrets-yaml-flow>] -> renders into $out; returns the play's rc
run() {
  local sec=${2:-}
  [ -n "$sec" ] || sec='{}'
  cat >"$tmp/play.yml" <<PLAY
- name: Vaultwarden test
  hosts: localhost
  gather_facts: false
  vars_files:
    - $PWD/ansible/inventory/group_vars/all/gateway.yml
  vars:
    inventory_hostname: apps
    site:
      domain: example.com
      gateway: {subdomain: internal}
      email: admin@example.com
      pve: {ip: 192.0.2.10}
      hosts:
        apps: {ip: 192.0.2.121, home_ip: 198.51.100.249}
      dns: {acme_resolvers: [198.51.100.53]}
      services: $1
    caddy_upstream_cas: {vault: /nonexistent/vault-ca.pem}
    vaultwarden_admin_token_hash: \$argon2id\$v=19\$m=19456,t=2,p=1\$ZmFrZXNhbHRmYWtlc2FsdA\$ZmFrZWhhc2hmYWtlaGFzaGZha2VoYXNo
    vaultwarden_backup_keys: {s3_access_key: FAKEACCESSKEY0000000, s3_secret_key: fakesecretkey0000000000000000000000000000}
    vaultwarden_backup_age_recipient: age1qyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqszqgpqyqs3290gq
    vaultwarden_secrets: $sec
    vaultwarden_vault_keys: "{{ vaultwarden_secrets.keys() | list }}"
  tasks:
    - name: Gateway routes
      ansible.builtin.include_role:
        name: caddy
        tasks_from: services.yml
        public: true
    - name: Route
      ansible.builtin.include_role:
        name: vaultwarden
        tasks_from: route.yml
        public: true
    - name: SMTP
      ansible.builtin.include_role:
        name: vaultwarden
        tasks_from: smtp.yml
        public: true
    - name: Dashboard entries
      ansible.builtin.include_role:
        name: homepage
        tasks_from: entries.yml
        public: true
    - name: Render
      ansible.builtin.template:
        src: "$PWD/ansible/roles/{{ item.role }}/templates/{{ item.src }}.j2"
        dest: "$out/{{ item.dest | default(item.src) }}"
        mode: "0600"
      loop:
        - {role: vaultwarden, src: docker-compose.yaml}
        - {role: vaultwarden, src: vaultwarden.env}
        - {role: vaultwarden, src: rclone.env}
        - {role: vaultwarden, src: vaultwarden-backup.sh}
        - {role: vaultwarden, src: vaultwarden-backup.service}
        - {role: vaultwarden, src: vaultwarden-backup.timer}
        - {role: caddy, src: Caddyfile}
        - {role: caddy, src: docker-compose.yaml, dest: caddy-compose.yaml}
        - {role: homepage, src: services.yaml}
PLAY
  rm -f "$out"/*
  ANSIBLE_ROLES_PATH=ansible/roles ANSIBLE_LOCALHOST_WARNING=false ANSIBLE_INVENTORY_UNPARSED_WARNING=false \
    ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/log" 2>&1
}

good='[
  {name: dns, container: pihole, port: 80, scheme: http, home: /admin/},
  {name: home, container: homepage, port: 3000, scheme: http},
  {name: pass, container: vaultwarden, port: 8080, scheme: http, websocket: true}]'
run "$good"
if [ "$?" -eq 0 ] && [ -s "$out/docker-compose.yaml" ]; then ok "good services render"
else bad_ "good services render"; tail -30 "$tmp/log"; exit 1; fi

c="$out/docker-compose.yaml"
check "compose: DOMAIN is the gateway name"   'grep -qx "      DOMAIN: \"https://pass.internal.example.com\"" "$c"'
check "compose: sign-ups closed, invitations on" 'grep -qx "      SIGNUPS_ALLOWED: \"false\"" "$c" && grep -qx "      INVITATIONS_ALLOWED: \"true\"" "$c"'
check "compose: no password hint shown"       'grep -qx "      SHOW_PASSWORD_HINT: \"false\"" "$c"'
check "compose: iterations not below default" 'grep -qx "      PASSWORD_ITERATIONS: \"600000\"" "$c"'
check "compose: no SMTP"                      '! grep -q SMTP "$c"'
check "compose: unprivileged port 8080"       'grep -qx "      ROCKET_PORT: \"8080\"" "$c"'
check "compose: no published port"            '! grep -qE "^\s+ports:" "$c"'
check "compose: image pinned by tag and digest" 'grep -qE "^    image: vaultwarden/server:[0-9.]+@sha256:[0-9a-f]{64}$" "$c"'
check "compose: runs as its own uid"          'grep -qx "    user: \"10004:10004\"" "$c"'
check "compose: read-only root, no capabilities" 'grep -qx "    read_only: true" "$c" && grep -qx "      - ALL" "$c" && grep -q "no-new-privileges:true" "$c"'
check "compose: memory cap 128m, swap included" 'grep -qx "    mem_limit: 128m" "$c" && grep -qx "    memswap_limit: 128m" "$c"'
check "compose: data under the project dir"   'grep -qx "      - ./data:/data" "$c"'
check "compose: admin token only from the env file" '! grep -v "^ *#" "$c" | grep -q ADMIN_TOKEN && grep -qx "    env_file: vaultwarden.env" "$c"'
check "compose: own network only"             '[ "$(awk "/^    networks:/{f=1;next} f&&/^      - /{print \$2} f&&!/^      - /{f=0}" "$c")" = web ]'
check "compose: health check"                 'grep -q "/healthcheck.sh" "$c"'
check "compose is valid YAML"                 'python3 -c "import sys,yaml; yaml.safe_load(open(sys.argv[1]))" "$c" || ruby -ryaml -e "YAML.safe_load(File.read(ARGV[0]))" "$c"'

e="$out/vaultwarden.env"
check "env: the argon2id hash, single-quoted"  '[ "$(grep -v "^#" "$e")" = "ADMIN_TOKEN='"'"'\$argon2id\$v=19\$m=19456,t=2,p=1\$ZmFrZXNhbHRmYWtlc2FsdA\$ZmFrZWhhc2hmYWtlaGFzaGZha2VoYXNo'"'"'" ]'

check "env: no SMTP without the login pair"   '! grep -q SMTP_ "$e" && ! grep -q SIGNUPS_VERIFY "$e" && grep -q "Vaultwarden runs without SMTP" "$tmp/log"'

r="$out/rclone.env"
check "rclone: Ceph endpoint from site"        'grep -qx "RCLONE_CONFIG_VWB_ENDPOINT=http://192.0.2.10:7480" "$r"'
check "rclone: keys from the role vars"        'grep -qx "RCLONE_CONFIG_VWB_ACCESS_KEY_ID=FAKEACCESSKEY0000000" "$r"'

u="$out/vaultwarden-backup.service"
check "unit: runs as the Vaultwarden user"     'grep -qx "User=vaultwarden" "$u"'
check "unit: S3 keys from a root-read env file" 'grep -qx "EnvironmentFile=/etc/vaultwarden-backup/rclone.env" "$u"'
check "unit: read-only system, private tmp"    'grep -qx "ProtectSystem=strict" "$u" && grep -qx "PrivateTmp=true" "$u" && grep -qx "ReadWritePaths=/opt/vaultwarden/data" "$u"'
check "timer: nightly, persistent"             'grep -qx "OnCalendar=\*-\*-\* 03:30:00" "$out/vaultwarden-backup.timer" && grep -qx "Persistent=true" "$out/vaultwarden-backup.timer"'

cf="$out/Caddyfile"
check "gateway: pass route to the container"   'grep -q "@pass host pass.internal.example.com" "$cf" && grep -q "reverse_proxy http://vaultwarden:8080" "$cf"'
check "gateway: websockets survive a reload"   'awk "/handle @pass/{f=1} f&&/stream_close_delay/{print; exit}" "$cf" | grep -q 5m'
check "gateway: Caddy joins vaultwarden_web"   'grep -qx "      - vaultwarden_web" "$out/caddy-compose.yaml" && grep -q "^  vaultwarden_web:" "$out/caddy-compose.yaml"'

s=$(grep -v '^#' "$out/services.yaml" | jq -c .) || s='[]'
check "dashboard: Vaultwarden under Security"  '[ "$(jq -r ".[] | select(has(\"Security\")) | .Security[] | select(has(\"Vaultwarden\")) | .Vaultwarden.href" <<<"$s")" = "https://pass.internal.example.com" ]'
check "dashboard: no widget, container status" '[ "$(jq -c ".[] | select(has(\"Security\")) | .Security[0].Vaultwarden | [has(\"widget\"), .container]" <<<"$s")" = "[false,\"vaultwarden\"]" ]'

check "no private address in the output"      '! grep -rqE "\b(10\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])|192\.168)\.[0-9]+\.[0-9]+" "$out"'

reject() {
  run "$2"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q 'site.services needs the enabled entry' "$tmp/log"; then ok "rejects $1"
  else bad_ "rejects $1"; fi
}
reject "pass on the root port"   '[{name: pass, container: vaultwarden, port: 80, scheme: http, websocket: true}]'
reject "pass without websocket"  '[{name: pass, container: vaultwarden, port: 8080, scheme: http}]'
reject "pass disabled"           '[{name: pass, container: vaultwarden, port: 8080, scheme: http, websocket: true, enabled: false}]'
reject "pass on a host address"  '[{name: pass, host: hosts.apps.ip, port: 8080, scheme: http, websocket: true}]'

# SMTP from Vault: Gmail defaults with only the pair; every setting overridable (Resend).
tfa="EMAIL_2FA_ENFORCE_ON_VERIFIED_INVITE='true' EMAIL_ATTEMPTS_LIMIT='3' EMAIL_EXPIRATION_TIME='600'"
envv() { grep -v '^#' "$out/vaultwarden.env" | grep -v '^ADMIN_TOKEN=' | LC_ALL=C sort | tr '\n' ' '; }
run "$good" '{smtp_username: someone@example.com, smtp_password: abcd efgh ijkl mnop}'
check "smtp: Gmail defaults, sender = login"  '[ "$(envv)" = "$tfa SIGNUPS_VERIFY='"'"'true'"'"' SMTP_FROM='"'"'someone@example.com'"'"' SMTP_FROM_NAME='"'"'Vaultwarden'"'"' SMTP_HOST='"'"'smtp.gmail.com'"'"' SMTP_PASSWORD='"'"'abcd efgh ijkl mnop'"'"' SMTP_PORT='"'"'587'"'"' SMTP_SECURITY='"'"'starttls'"'"' SMTP_USERNAME='"'"'someone@example.com'"'"' _ENABLE_EMAIL_2FA='"'"'true'"'"' " ]'
run "$good" '{smtp_host: smtp.resend.com, smtp_port: 465, smtp_security: force_tls, smtp_username: resend, smtp_password: re_fakekey123456, smtp_from: vault@example.com}'
check "smtp: Resend, every setting from Vault" '[ "$(envv)" = "$tfa SIGNUPS_VERIFY='"'"'true'"'"' SMTP_FROM='"'"'vault@example.com'"'"' SMTP_FROM_NAME='"'"'Vaultwarden'"'"' SMTP_HOST='"'"'smtp.resend.com'"'"' SMTP_PASSWORD='"'"'re_fakekey123456'"'"' SMTP_PORT='"'"'465'"'"' SMTP_SECURITY='"'"'force_tls'"'"' SMTP_USERNAME='"'"'resend'"'"' _ENABLE_EMAIL_2FA='"'"'true'"'"' " ]'
reject_smtp() {
  run "$good" "$2"; rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$3" "$tmp/log"; then ok "smtp rejects $1"; else bad_ "smtp rejects $1"; fi
}
reject_smtp "a username alone"    '{smtp_username: someone@example.com}' 'holds only one of smtp_username and smtp_password'
reject_smtp "a password alone"    '{smtp_password: abcdefghijkl}' 'holds only one of smtp_username and smtp_password'
reject_smtp "a non-numeric port"  '{smtp_username: a@example.com, smtp_password: abcdefghijkl, smtp_port: "58x"}' 'smtp_port must be a port number'
reject_smtp "an unknown security" '{smtp_username: a@example.com, smtp_password: abcdefghijkl, smtp_security: ssl}' 'smtp_security must be starttls, force_tls or off'
reject_smtp "a quote in the password" "{smtp_username: a@example.com, smtp_password: \"abc'defghij\"}" 'smtp_from (default smtp_username) an email address'
reject_smtp "no sender address"   '{smtp_username: resend, smtp_password: re_fakekey123456}' 'smtp_from (default smtp_username) an email address'
check "smtp: the password never in the log"  '! grep -rq "re_fakekey123456\|abcdefghijkl" "$tmp/log"'

# --- backup script ---------------------------------------------------------------------------
run "$good" >/dev/null
b="$tmp/backup"
mkdir -p "$b/data/attachments/c1" "$b/data/sends/s1" "$b/data/icon_cache" "$b/data/tmp" "$b/bin" "$b/s3/bucket" "$b/tmp"
sqlite3 "$b/data/db.sqlite3" 'PRAGMA journal_mode=WAL; CREATE TABLE users (uuid TEXT PRIMARY KEY, email TEXT);
  INSERT INTO users VALUES ("u1", "one@example.com"), ("u2", "two@example.com");' >/dev/null
echo attachment >"$b/data/attachments/c1/a1"
echo send >"$b/data/sends/s1/f1"
echo key >"$b/data/rsa_key.pem"
echo '{"domain": "https://pass.internal.example.com"}' >"$b/data/config.json"
echo icon >"$b/data/icon_cache/x.png"
age-keygen -o "$b/key" 2>/dev/null
age-keygen -y "$b/key" >"$b/recipients"
# fake rclone: vwb:<bucket>[/<name>] is the directory $b/s3/<bucket>
cat >"$b/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_S3:?}
p() { local x=${1#vwb:}; printf '%s/%s' "$root" "$x"; }
cmd=$1; shift
case $cmd in
  copyto) [ "$1" = --s3-no-check-bucket ] && shift; cp "$1" "$(p "$2")" ;;
  lsf)
    if [ "$1" = --format ]; then wc -c <"$(p "$3")" | tr -d ' '
    else [ "$1" = --files-only ] && shift; ls -1 "$(p "$1")"; fi ;;
  deletefile) rm "$(p "$1")" ;;
  *) echo "fake rclone: $cmd" >&2; exit 2 ;;
esac
FAKE
chmod +x "$b/bin/rclone"
for i in $(seq -w 1 15); do echo old >"$b/s3/bucket/vaultwarden-200001${i}-000000.tar.age"; done
echo foreign >"$b/s3/bucket/other-file.txt"
echo foreign >"$b/s3/bucket/vaultwarden-manual.tar.age"

PATH="$b/bin:$PATH" FAKE_S3="$b/s3" TMPDIR="$b/tmp" VW_BACKUP_DATA="$b/data" VW_BACKUP_RECIPIENTS="$b/recipients" \
  VW_BACKUP_REMOTE=vwb:bucket VW_BACKUP_KEEP=14 bash "$out/vaultwarden-backup.sh" >"$b/log" 2>&1
rc=$?
check "backup: script succeeds"                '[ "$rc" = 0 ]' || cat "$b/log"
new=$(ls "$b/s3/bucket" | grep -E '^vaultwarden-[0-9]{8}-[0-9]{6}\.tar\.age$' | sort -r | head -n 1)
check "backup: uploaded under a dated name"    '[ -n "$new" ] && [ "${new#vaultwarden-2000}" = "$new" ]'
check "backup: the object is age-encrypted"    '[ "$(head -c 21 "$b/s3/bucket/$new")" = "age-encryption.org/v1" ]'
mkdir "$b/restore"
age -d -i "$b/key" "$b/s3/bucket/$new" | tar -x -f - -C "$b/restore"
check "backup: archive holds the files"     '[ "$(age -d -i "$b/key" "$b/s3/bucket/$new" | tar -t -f - | grep -cE "^vaultwarden/(db.sqlite3|rsa_key.pem|config.json|attachments/c1/a1|sends/s1/f1)$")" = 5 ]'
check "backup: database copy with the users"   '[ "$(sqlite3 "$b/restore/vaultwarden/db.sqlite3" "SELECT group_concat(email) FROM users ORDER BY uuid")" = "one@example.com,two@example.com" ]'
check "backup: attachments, sends, key, config" '[ -f "$b/restore/vaultwarden/attachments/c1/a1" ] && [ -f "$b/restore/vaultwarden/sends/s1/f1" ] && [ -f "$b/restore/vaultwarden/rsa_key.pem" ] && [ -f "$b/restore/vaultwarden/config.json" ]'
check "backup: no icon cache, tmp or WAL files" '! age -d -i "$b/key" "$b/s3/bucket/$new" | tar -t -f - | grep -qE "icon_cache|/tmp/|-wal|-shm"'
check "backup: keeps the newest 14 of its own" '[ "$(ls "$b/s3/bucket" | grep -cE "^vaultwarden-[0-9]{8}-[0-9]{6}\.tar\.age$")" = 14 ] && [ ! -e "$b/s3/bucket/vaultwarden-20000102-000000.tar.age" ] && [ -e "$b/s3/bucket/vaultwarden-20000103-000000.tar.age" ]'
check "backup: other objects untouched"        '[ -f "$b/s3/bucket/other-file.txt" ] && [ -f "$b/s3/bucket/vaultwarden-manual.tar.age" ]'
check "backup: work directory removed"         '[ -z "$(ls -A "$b/tmp")" ]'

# A failed upload check stops the job before pruning.
cat >"$b/bin/rclone2" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = lsf ] && [ "${2:-}" = --format ] && { echo 1; exit 0; }
exec "$(dirname "$0")/rclone.real" "$@"
FAKE
mv "$b/bin/rclone" "$b/bin/rclone.real"; mv "$b/bin/rclone2" "$b/bin/rclone"; chmod +x "$b/bin/rclone"
before=$(ls "$b/s3/bucket" | wc -l)
sleep 1
PATH="$b/bin:$PATH" FAKE_S3="$b/s3" TMPDIR="$b/tmp" VW_BACKUP_DATA="$b/data" VW_BACKUP_RECIPIENTS="$b/recipients" \
  VW_BACKUP_REMOTE=vwb:bucket VW_BACKUP_KEEP=14 bash "$out/vaultwarden-backup.sh" >"$b/log2" 2>&1
rc=$?
check "backup: a size mismatch fails the job"  '[ "$rc" -ne 0 ] && grep -q "uploaded size differs" "$b/log2"'
check "backup: and nothing is pruned"          '[ "$(ls "$b/s3/bucket" | wc -l)" -eq $((before + 1)) ]'

exit "$fail"
