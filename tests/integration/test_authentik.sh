#!/usr/bin/env bash
# Authentik (role authentik): the templates render, the secrets stay in the mode 600 env
# files (Postgres gets only its own), only the HTTP port is published, on the lab address,
# the images are pinned, the memory caps fit the VM, and the role is wired into vms.yml, the
# gateway example and Homepage.
# The backup job runs with a fake docker (pg_dump writes fixed bytes) and a fake rclone (a
# local directory as the bucket): the dump is encrypted with age on the way, uploaded under a
# dated name and checked, pruning keeps the newest KEEP of the job's own objects, and a
# failed dump or a stopped database uploads nothing. make backup's pull of the newest object
# runs with a fake vault and aws.
# Uses documentation-range addresses and example.com only. Needs ansible, jq and age.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
for c in ansible-playbook jq age age-keygen; do
  command -v "$c" >/dev/null || { echo "FAIL $c not found"; exit 1; }
done

# Homepage's catalog, as the tiles read it (after the role defaults, so it wins).
cat >"$tmp/catalog.yml" <<'CATALOG'
authentik_tiles_catalog:
  sonarr: {title: Sonarr, group: Media, icon: sonarr.png, description: TV series}
  tv: {title: TV, group: Media, icon: mdi-television-classic, description: Live TV}
CATALOG
cat >"$tmp/play.yml" <<PLAY
- name: Authentik templates
  hosts: localhost
  gather_facts: false
  vars:
    inventory_hostname: identity
    gateway_domain: lab.example.com
    site:
      email: admin@example.com
      services:
        - {name: pve, host: pve.ip, port: 8006, scheme: https}
        - {name: pve2, host: network.pve2_ip, port: "8006", scheme: https}
        - {name: old, host: pve.ip, port: 8006, scheme: https, enabled: false}
        - {name: auth, host: hosts.identity.ip, port: 9000, scheme: http}
        - {name: sonarr, host: hosts.ragnarok.ip, port: 8989, scheme: http}
        - {name: ceph, host: pve.ip, port: 8443, scheme: https}
        - {name: tv, host: hosts.ragnarok.ip, port: 34401, scheme: http, title: Live TV}
        - {name: mystery, host: hosts.ragnarok.ip, port: 1234, scheme: http}
      pve: {ip: 192.0.2.10}
      hosts: {identity: {ip: 192.0.2.125, home_ip: 198.51.100.48}, apps: {ip: 192.0.2.121}}
    authentik_secrets:
      secret_key: test-secret-key
      postgres_password: test-postgres-password
      bootstrap_password: test-bootstrap-password
      bootstrap_token: test-bootstrap-token
      proxmox_client_secret: test-proxmox-client-secret
    authentik_backup_keys: {s3_access_key: FAKEACCESSKEY0000000, s3_secret_key: fakesecretkey0000000000000000000000000000}
  vars_files:
    - $PWD/ansible/roles/authentik/defaults/main.yml
    - $tmp/catalog.yml
  tasks:
    - ansible.builtin.template:
        src: $PWD/ansible/roles/authentik/templates/{{ item }}.j2
        dest: $tmp/{{ item }}
        mode: "0600"
      loop: [docker-compose.yaml, authentik.env, db.env, rclone.env, authentik-backup.sh,
             authentik-backup.service, authentik-backup.timer, anvil-sso.yaml]
    - ansible.builtin.copy:
        content: "{{ authentik_vault_path }} {{ authentik_secret_keys | join(',') }}"
        dest: $tmp/vault
        mode: "0600"
PLAY
if ansible-playbook -i localhost, -c local "$tmp/play.yml" >"$tmp/render.log" 2>&1; then ok "templates render"; else
  bad_ "templates render"; cat "$tmp/render.log"; exit 1; fi

c=$tmp/docker-compose.yaml
secrets='test-secret-key|test-postgres-password|test-bootstrap-password|test-bootstrap-token|test-proxmox-client-secret'
# shellcheck disable=SC2329  # called through check's eval
py() { python3 -c "import yaml; s=yaml.safe_load(open('$c'))['services']; $1"; }

check "compose: valid YAML with server, worker and db (no Redis since 2025.10)" \
  "py 'assert sorted(s)==[\"db\",\"server\",\"worker\"]'"
check "compose: no secret value in the compose file" "! grep -q -E '$secrets' '$c'"
check "compose: only the server is published, port 9000 on the lab address" \
  "py 'assert s[\"server\"][\"ports\"]==[\"192.0.2.125:9000:9000\"]; assert \"ports\" not in s[\"worker\"] and \"ports\" not in s[\"db\"]'"
check "compose: nothing on the home address, no 9443 and no LDAP port" \
  "! grep -v '^ *#' '$c' | grep -q -E '198\.51\.100\.48|9443|:389|:636|:3389|:6636'"
check "compose: every image is pinned by digest" "[ \$(grep -c 'image: .*@sha256:[a-f0-9]\{64\}' '$c') = 3 ]"
check "compose: server and worker run the same Authentik image" \
  "py 'assert s[\"server\"][\"image\"]==s[\"worker\"][\"image\"] and s[\"server\"][\"image\"].startswith(\"ghcr.io/goauthentik/server:\")'"
check "compose: server and worker wait for a healthy db" \
  "py 'assert all(s[n][\"depends_on\"]==dict(db={\"condition\":\"service_healthy\"}) for n in (\"server\",\"worker\"))'"
check "compose: memory capped with no swap on every service" \
  "py 'assert all(v[\"mem_limit\"]==v[\"memswap_limit\"] for v in s.values())'"
check "compose: the caps add up to at most 2 GB of the VM's 3 GB" \
  "py 'assert sum(int(v[\"mem_limit\"].rstrip(\"m\")) for v in s.values()) <= 2048'"
check "compose: the worker has no Docker socket and does not run as root" \
  "py 'w=s[\"worker\"]; assert \"user\" not in w and not any(\"docker.sock\" in v for v in w[\"volumes\"])'"
check "compose: forwarded headers trusted from the gateway's lab address only" \
  "py 'assert all(s[n][\"environment\"][\"AUTHENTIK_LISTEN__TRUSTED_PROXY_CIDRS\"]==\"192.0.2.121/32\" for n in (\"server\",\"worker\"))'"
check "compose: each container reads only its own env file" \
  "py 'assert s[\"server\"][\"env_file\"]==s[\"worker\"][\"env_file\"]==\"authentik.env\" and s[\"db\"][\"env_file\"]==\"db.env\"'"
check "authentik.env: the four secrets and the bootstrap email, no Postgres password variable" \
  "grep -qx 'AUTHENTIK_SECRET_KEY=test-secret-key' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_POSTGRESQL__PASSWORD=test-postgres-password' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_BOOTSTRAP_PASSWORD=test-bootstrap-password' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_BOOTSTRAP_TOKEN=test-bootstrap-token' '$tmp/authentik.env' &&
   grep -qx 'AUTHENTIK_BOOTSTRAP_EMAIL=admin@example.com' '$tmp/authentik.env' &&
   ! grep -q POSTGRES_PASSWORD '$tmp/authentik.env'"
check "db.env: only the Postgres password" \
  "[ \"\$(grep -v '^#' '$tmp/db.env')\" = 'POSTGRES_PASSWORD=test-postgres-password' ]"
check "vault: kv/homelab/identity/authentik with the five keys" \
  "[ \"\$(cat '$tmp/vault')\" = 'homelab/identity/authentik secret_key,postgres_password,bootstrap_password,bootstrap_token,proxmox_client_secret' ]"

check "authentik.env: the Proxmox client secret for the blueprint" \
  "grep -qx 'ANVIL_PROXMOX_CLIENT_SECRET=test-proxmox-client-secret' '$tmp/authentik.env'"
check "compose: the worker reads anvil's blueprints read-only, the server does not" \
  "py 'assert \"./blueprints:/blueprints/anvil:ro\" in s[\"worker\"][\"volumes\"] and not any(\"blueprints\" in v for v in s[\"server\"][\"volumes\"])'"

# The single sign-on blueprint. Authentik's tags (!Find, !KeyOf, !Env) load as [tag, args...].
sso=$tmp/anvil-sso.yaml
# shellcheck disable=SC2329  # called through check's eval
bpy() { python3 -c "
import yaml, re
class L(yaml.SafeLoader): pass
def tag(l, t, n):
    return ['!' + t] + (l.construct_sequence(n) if isinstance(n, yaml.SequenceNode) else [l.construct_scalar(n)])
L.add_multi_constructor('!', tag)
e=yaml.load(open('$sso'), Loader=L)['entries']
by=lambda m: [x for x in e if x['model']==m]
$1"; }
check "blueprint: no secret value in it, the client secret from the environment" \
  "! grep -q -E '$secrets' '$sso' && grep -q 'client_secret: !Env \[ANVIL_PROXMOX_CLIENT_SECRET, \"\"\]' '$sso'"
check "blueprint: one group, the default lab-admins" \
  "bpy 'assert [x[\"identifiers\"] for x in by(\"authentik_core.group\")]==[dict(name=\"lab-admins\")]'"
check "blueprint: every login needs a second factor, set up at the next login when missing" \
  "bpy 'm=by(\"authentik_stages_authenticator_validate.authenticatorvalidatestage\"); assert len(m)==1
a=m[0][\"attrs\"]; assert m[0][\"identifiers\"]==dict(name=\"default-authentication-mfa-validation\")
assert a[\"not_configured_action\"]==\"configure\" and sorted(a[\"device_classes\"])==[\"static\",\"totp\",\"webauthn\"]
assert [c[2][1] for c in a[\"configuration_stages\"]]==[\"default-authenticator-totp-setup\",\"default-authenticator-webauthn-setup\"]'"
check "blueprint: the gateway provider is domain mode for the gateway domain, at auth" \
  "bpy 'p=by(\"authentik_providers_proxy.proxyprovider\")[0][\"attrs\"]
assert p[\"mode\"]==\"forward_domain\" and p[\"cookie_domain\"]==\"lab.example.com\" and p[\"external_host\"]==\"https://auth.lab.example.com\"'"
check "blueprint: the embedded outpost serves the gateway provider at the browser's address" \
  "bpy 'o=by(\"authentik_outposts.outpost\")[0]; assert o[\"identifiers\"]==dict(managed=\"goauthentik.io/outposts/embedded\")
assert o[\"attrs\"][\"providers\"]==[[\"!KeyOf\",\"gateway-provider\"]] and o[\"attrs\"][\"config\"][\"authentik_host\"]==\"https://auth.lab.example.com\"'"
check "blueprint: every app is bound to the group only" \
  "bpy 'b=by(\"authentik_policies.policybinding\"); assert len(b)==7 and all(x[\"identifiers\"][\"group\"]==[\"!KeyOf\",\"sso-group\"] for x in b)'"
check "blueprint: Proxmox may use the login code flow and refresh tokens, nothing else" \
  "bpy 'p=by(\"authentik_providers_oauth2.oauth2provider\")[0][\"attrs\"]; assert p[\"grant_types\"]==[\"authorization_code\",\"refresh_token\"]'"
check "blueprint: a tile per service except auth and the Proxmox app's name, a disabled one removed" \
  "bpy 't={x[\"identifiers\"][\"slug\"]: x for x in by(\"authentik_core.application\") if x[\"identifiers\"][\"slug\"].startswith(\"lab-\") and x[\"identifiers\"][\"slug\"]!=\"lab-gateway\"}
assert sorted(t)==[\"lab-ceph\",\"lab-mystery\",\"lab-old\",\"lab-pve2\",\"lab-sonarr\",\"lab-tv\"], sorted(t)
assert t[\"lab-old\"][\"state\"]==\"absent\" and t[\"lab-ceph\"][\"state\"]==\"absent\"
assert all(t[k][\"state\"]==\"present\" for k in t if k not in (\"lab-old\",\"lab-ceph\"))'"
check "blueprint: tiles take Homepage's catalog, an entry's own fields win, unknown names get defaults" \
  "bpy 't={x[\"identifiers\"][\"slug\"]: x.get(\"attrs\", {}) for x in by(\"authentik_core.application\")}
s=t[\"lab-sonarr\"]; assert (s[\"name\"], s[\"group\"], s[\"meta_launch_url\"])==(\"Sonarr\",\"Media\",\"https://sonarr.lab.example.com\")
assert s[\"meta_icon\"]==\"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/sonarr.png\"
assert t[\"lab-tv\"][\"name\"]==\"Live TV\" and t[\"lab-tv\"][\"meta_icon\"]==\"\"
assert (t[\"lab-mystery\"][\"name\"], t[\"lab-mystery\"][\"group\"])==(\"mystery\",\"Other\")'"
check "blueprint: every present tile is bound to the group only" \
  "bpy 'b=[x[\"identifiers\"][\"target\"][1] for x in by(\"authentik_policies.policybinding\")]
assert sorted(b)==[\"ceph-app\",\"gateway-app\",\"proxmox-app\",\"tile-mystery\",\"tile-pve2\",\"tile-sonarr\",\"tile-tv\"], b'"
check "blueprint: Ceph logs in by SAML at its gateway name, by Authentik user name" \
  "bpy 'p=by(\"authentik_providers_saml.samlprovider\")[0][\"attrs\"]
assert p[\"acs_url\"]==\"https://ceph.lab.example.com/auth/saml2\" and p[\"audience\"]==\"https://ceph.lab.example.com/auth/saml2/metadata\"
assert p[\"sp_binding\"]==\"post\" and p[\"sign_assertion\"] is True and p[\"name_id_mapping\"][2][1]==\"goauthentik.io/providers/saml/username\"
a=[x for x in by(\"authentik_core.application\") if x[\"identifiers\"][\"slug\"]==\"ceph\"][0]; assert a[\"attrs\"][\"provider\"]==[\"!KeyOf\",\"ceph-provider\"]'"
check "blueprint: Proxmox redirects only to the enabled port 8006 names" \
  "bpy 'u=by(\"authentik_providers_oauth2.oauth2provider\")[0][\"attrs\"][\"redirect_uris\"]; assert len(u)==1 and u[0][\"matching_mode\"]==\"regex\"
r=re.compile(u[0][\"url\"])
assert r.match(\"https://pve.lab.example.com\") and r.match(\"https://pve2.lab.example.com/\")
assert not any(r.match(x) for x in [\"https://old.lab.example.com\",\"https://pveXlab.example.com\",\"https://pve.lab.example.com.evil.test\",\"http://pve.lab.example.com\",\"https://auth.lab.example.com\"])'"

# The role's tasks: env files mode 600 and never logged, secrets only added, the health check.
t=ansible/roles/authentik/tasks/main.yml
# shellcheck disable=SC2329  # called through check's eval
tpy() { python3 -c "import yaml; t={x['name']: x for x in yaml.safe_load(open('$t'))}; $1"; }
check "tasks: env files are written mode 0600 with no_log and no diff" \
  "tpy 'x=t[\"Env files (secrets from Vault)\"]; assert x[\"ansible.builtin.copy\"][\"mode\"]==\"0600\" and x[\"no_log\"] is True and x[\"diff\"] is False'"
check "tasks: the secrets are read with no_log" "tpy 'assert t[\"Read the Authentik secrets from Vault\"][\"no_log\"] is True'"
check "tasks: only missing keys are generated, an empty path with put -cas=0" \
  "tpy 'x=t[\"Generate the missing secrets into Vault\"]; assert \"put -cas=0\" in x[\"ansible.builtin.shell\"][\"cmd\"] and \"difference(authentik_vault_keys)\" in x[\"vars\"][\"authentik_missing\"]'"
check "tasks: the run ends on the health endpoint" \
  "tpy 'assert t[\"Authentik answers\"][\"ansible.builtin.uri\"][\"url\"].endswith(\"/-/health/ready/\")'"

# Wiring: vms.yml (after the Docker play), the gateway example and the Homepage catalog.
check "vms.yml: role authentik with tag authentik on identity_servers, after Docker" \
  "python3 -c 'import yaml; p=yaml.safe_load(open(\"ansible/playbooks/vms.yml\")); n=[x[\"name\"] for x in p]
i=[k for k,x in enumerate(p) if any(r.get(\"role\")==\"authentik\" for r in x.get(\"roles\",[]))]
assert len(i)==1 and p[i[0]][\"hosts\"]==\"identity_servers\" and i[0]>n.index(\"Docker\")
assert [r for r in p[i[0]][\"roles\"] if r[\"role\"]==\"authentik\"][0][\"tags\"]==[\"authentik\"]'"
check "site.example.yml: the auth entry points at the identity VM's lab address" \
  "python3 -c 'import yaml; s=yaml.safe_load(open(\"site/site.example.yml\"))[\"site\"][\"services\"]; a=[x for x in s if x[\"name\"]==\"auth\"]
assert a==[dict(name=\"auth\",host=\"hosts.identity.ip\",port=9000,scheme=\"http\",websocket=True)]'"
check "homepage: catalog entry auth in Security, no widget" \
  "python3 -c 'import yaml; c=yaml.safe_load(open(\"ansible/roles/homepage/defaults/main.yml\"))[\"homepage_catalog\"][\"auth\"]
assert c==dict(title=\"Authentik\",group=\"Security\",icon=\"authentik.png\",description=\"Single sign-on\",widget=\"none\")'"

# --- backup job --------------------------------------------------------------------------------
r=$tmp/rclone.env
check "rclone: Ceph endpoint from site, keys from Vault" \
  "grep -qx 'RCLONE_CONFIG_AKB_ENDPOINT=http://192.0.2.10:7480' '$r' && grep -qx 'RCLONE_CONFIG_AKB_ACCESS_KEY_ID=FAKEACCESSKEY0000000' '$r'"
u=$tmp/authentik-backup.service
check "unit: S3 keys from a root-read env file" "grep -qx 'EnvironmentFile=/etc/authentik-backup/rclone.env' '$u'"
check "unit: private /var/tmp as the work directory, read-only system" \
  "grep -qx 'PrivateTmp=true' '$u' && grep -qx 'Environment=TMPDIR=/var/tmp HOME=/var/tmp' '$u' && grep -qx 'ProtectSystem=strict' '$u' && grep -qx 'ProtectHome=true' '$u'"
check "timer: nightly, persistent" \
  "grep -qx 'OnCalendar=\*-\*-\* 03:45:00' '$tmp/authentik-backup.timer' && grep -qx 'Persistent=true' '$tmp/authentik-backup.timer'"
check "tasks: S3 env file mode 0600 with no_log" \
  "python3 -c 'import yaml; t={x[\"name\"]: x for x in yaml.safe_load(open(\"ansible/roles/authentik/tasks/backup.yml\"))}
x=t[\"S3 remote for the job (keys from Vault)\"]; assert x[\"ansible.builtin.copy\"][\"mode\"]==\"0600\" and x[\"no_log\"] is True
assert t[\"Read the backup S3 keys from Vault\"][\"no_log\"] is True'"

b=$tmp/backup
mkdir -p "$b/bin" "$b/s3/bucket" "$b/tmp"
age-keygen -o "$b/key" 2>/dev/null
age-keygen -y "$b/key" >"$b/recipients"
# The dump the fake pg_dump writes: a custom-format header and 20 KB of bytes.
{ printf 'PGDMP'; head -c 20000 /dev/urandom; } >"$b/dump"
# fake docker: inspect says FAKE_RUNNING, psql prints a database size, pg_dump prints the
# dump (or half of it and fails with FAKE_DUMP_FAIL=1). The Postgres arguments are checked.
cat >"$b/bin/docker" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "inspect --format") [ "$4" = authentik-db ] && echo "${FAKE_RUNNING:-true}"; exit 0 ;;
esac
[ "$1" = exec ] && [ "$2" = authentik-db ] || { echo "fake docker: $*" >&2; exit 2; }
case $3 in
  psql) echo 8388608 ;;
  pg_dump)
    [ "$*" = "exec authentik-db pg_dump -U authentik -d authentik --format=custom" ] || exit 3
    if [ "${FAKE_DUMP_FAIL:-0}" = 1 ]; then head -c 9000 "$FAKE_DUMP"; exit 1; fi
    cat "$FAKE_DUMP" ;;
  *) exit 2 ;;
esac
FAKE
# fake rclone: akb:<bucket>[/<name>] is the directory $b/s3/<bucket>
cat >"$b/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
root=${FAKE_S3:?}
p() { local x=${1#akb:}; printf '%s/%s' "$root" "$x"; }
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
chmod +x "$b/bin/docker" "$b/bin/rclone"
for i in $(seq -w 1 15); do echo old >"$b/s3/bucket/authentik-200001${i}-000000.dump.age"; done
echo foreign >"$b/s3/bucket/other-file.txt"
echo foreign >"$b/s3/bucket/authentik-manual.dump.age"

job() {
  PATH="$b/bin:$PATH" FAKE_S3="$b/s3" FAKE_DUMP="$b/dump" TMPDIR="$b/tmp" AK_BACKUP_RECIPIENTS="$b/recipients" \
    AK_BACKUP_REMOTE=akb:bucket AK_BACKUP_KEEP=14 "$@" bash "$tmp/authentik-backup.sh" >"$b/log" 2>&1
}
ours() { find "$b/s3/bucket" -type f -exec basename {} \; | grep -E '^authentik-[0-9]{8}-[0-9]{6}\.dump\.age$'; }

job env
rc=$?
check "backup: the job succeeds" "[ '$rc' = 0 ]" || cat "$b/log"
new=$(ours | sort -r | head -n 1)
check "backup: uploaded under a dated name" "[ -n '$new' ] && [ '${new#authentik-2000}' = '$new' ]"
check "backup: the object is age-encrypted" "[ \"\$(head -c 21 '$b/s3/bucket/$new')\" = age-encryption.org/v1 ]"
check "backup: it decrypts to the exact dump" "age -d -i '$b/key' '$b/s3/bucket/$new' | cmp -s - '$b/dump'"
check "backup: keeps the newest 14 of its own" \
  "[ \$(ours | wc -l) -eq 14 ] && [ ! -e '$b/s3/bucket/authentik-20000102-000000.dump.age' ] && [ -e '$b/s3/bucket/authentik-20000103-000000.dump.age' ]"
check "backup: other objects untouched" "[ -f '$b/s3/bucket/other-file.txt' ] && [ -f '$b/s3/bucket/authentik-manual.dump.age' ]"
check "backup: work directory removed" "[ -z \"\$(ls -A '$b/tmp')\" ]"

before=$(find "$b/s3/bucket" -type f | wc -l)
sleep 1
job env FAKE_DUMP_FAIL=1
rc=$?
check "backup: a failed pg_dump fails the job" "[ '$rc' -ne 0 ] && grep -q 'pg_dump or encryption failed' '$b/log'"
check "backup: and uploads nothing" "[ \$(find '$b/s3/bucket' -type f | wc -l) -eq $before ] && [ -z \"\$(ls -A '$b/tmp')\" ]"
job env FAKE_RUNNING=false
rc=$?
check "backup: a stopped database fails the job" "[ '$rc' -ne 0 ] && grep -q 'is not running' '$b/log' && [ \$(find '$b/s3/bucket' -type f | wc -l) -eq $before ]"

# A failed upload check stops the job before pruning.
mv "$b/bin/rclone" "$b/bin/rclone.real"
cat >"$b/bin/rclone" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = lsf ] && [ "${2:-}" = --format ] && { echo 1; exit 0; }
exec "$(dirname "$0")/rclone.real" "$@"
FAKE
chmod +x "$b/bin/rclone"
sleep 1
job env
rc=$?
check "backup: a size mismatch fails the job" "[ '$rc' -ne 0 ] && grep -q 'uploaded size differs' '$b/log'"
check "backup: and nothing is pruned" "[ \$(find '$b/s3/bucket' -type f | wc -l) -eq $((before + 1)) ]"

# --- make backup: the newest object of each bucket comes to the Mac ------------------------------
m=$tmp/pull
mkdir -p "$m/bin" "$m/home" "$m/s3/authentik-backups"
printf 'age-encryption.org/v1\nold\n' >"$m/s3/authentik-backups/authentik-20260101-000000.dump.age"
printf 'age-encryption.org/v1\nnew\n' >"$m/s3/authentik-backups/authentik-20260102-000000.dump.age"
echo foreign >"$m/s3/authentik-backups/authentik-manual.dump.age"
# fake vault: keys for the Authentik path only. fake aws: the bucket is a directory, and the
# keys must come through the environment.
cat >"$m/bin/vault" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *homelab/identity/authentik-backup) echo '{"data":{"data":{"s3_access_key":"FAKEACCESSKEY0000000","s3_secret_key":"fakesecret"}}}' ;;
  *) echo "No value found at kv/data/${*: -1}" >&2; exit 2 ;;
esac
FAKE
cat >"$m/bin/aws" <<'FAKE'
#!/usr/bin/env bash
[ "$AWS_ACCESS_KEY_ID" = FAKEACCESSKEY0000000 ] && [ "$AWS_SECRET_ACCESS_KEY" = fakesecret ] || exit 9
case "$*" in *fakesecret*) exit 8 ;; esac
shift 2
case "$2" in
  list-objects-v2) ls -1 "$FAKE_S3/$4" | jq -R . | jq -s '{Contents: map({Key: .})}' ;;
  get-object) cp "$FAKE_S3/$4/$6" "$7"; echo '{}' ;;
esac
FAKE
chmod +x "$m/bin/vault" "$m/bin/aws"
# The pull function from scripts/backup.sh, with its helpers.
{
  echo 'set -euo pipefail; die() { echo "backup: $*" >&2; exit 1; }; keep=30; part=; PVE_IP=192.0.2.10'
  sed -n '/^prune() {/,/^}/p; /^pull() {/,/^}/p; /^pull /,/dump\\.age/p' scripts/backup.sh
} >"$m/run.sh"
PATH="$m/bin:$PATH" FAKE_S3="$m/s3" dir="$m/home" bash -c '. "$1"' _ "$m/run.sh" >"$m/log" 2>&1
rc=$?
check "make backup: runs both pulls" "[ '$rc' = 0 ] && grep -q 'Vaultwarden skipped' '$m/log'" || cat "$m/log"
check "make backup: copies the newest Authentik backup, mode 600" \
  "[ \"\$(ls '$m/home')\" = authentik-20260102-000000.dump.age ] && [ \"\$(stat -c %a '$m/home/authentik-20260102-000000.dump.age' 2>/dev/null || stat -f %Lp '$m/home/authentik-20260102-000000.dump.age')\" = 600 ]"

[ "$fail" = 0 ] && echo "PASS: authentik" || echo "FAIL: authentik"
exit "$fail"
