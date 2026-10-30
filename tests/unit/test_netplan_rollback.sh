#!/usr/bin/env bash
# Netplan rollback script test: runs locally with stubbed netplan/ping and temp dirs.
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

script=ansible/roles/guest_base/files/netplan-rollback.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/backup" "$tmp/netplan"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }  # GNU first: GNU `stat -f` means filesystem status

cat >"$tmp/bin/netplan" <<STUB
#!/bin/sh
echo "netplan \$*" >>"$tmp/calls"
STUB
chmod +x "$tmp/bin/netplan"
reset() {
  find "$tmp/netplan" -type f -delete
  printf NEW >"$tmp/netplan/70-new.yaml"; chmod 644 "$tmp/netplan/70-new.yaml"
  : >"$tmp/calls"
}
printf OLD >"$tmp/backup/60-old.yaml"; chmod 600 "$tmp/backup/60-old.yaml"

# Case 1: target unreachable -> new file removed, backup restored (0600), netplan apply
printf '#!/bin/sh\necho "$*" >>"%s/pingargs"\nexit 1\n' "$tmp" >"$tmp/bin/ping"; chmod +x "$tmp/bin/ping"
reset
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --wait 1 --target 192.0.2.10 --netplan-dir "$tmp/netplan"
check "unreachable: rc" "$?" "0"
check "unreachable: files are exactly the backup" "$(ls "$tmp/netplan")" "60-old.yaml"
check "unreachable: content restored" "$(cat "$tmp/netplan/60-old.yaml")" "OLD"
check "unreachable: mode 600" "$(mode_of "$tmp/netplan/60-old.yaml")" "600"
check "unreachable: pinged the target" "$(grep -c -- '192.0.2.10' "$tmp/pingargs")" "1"
check "unreachable: netplan apply called" "$(cat "$tmp/calls")" "netplan apply"

# Case 2: target reachable -> leave the new files alone
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/ping"
reset
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --wait 0 --target 192.0.2.10 --netplan-dir "$tmp/netplan"
check "reachable: new file kept" "$(ls "$tmp/netplan")" "70-new.yaml"
check "reachable: no netplan apply" "$(cat "$tmp/calls")" ""

# Case 3: --force restores without pinging
reset
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --force --netplan-dir "$tmp/netplan"
check "force: files are exactly the backup" "$(ls "$tmp/netplan")" "60-old.yaml"
check "force: netplan apply called" "$(cat "$tmp/calls")" "netplan apply"

# Case 4: empty backup dir -> non-zero, nothing touched
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/ping"
mkdir "$tmp/empty"; reset
rc=yes
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/empty" --wait 0 --target 192.0.2.10 --netplan-dir "$tmp/netplan" 2>/dev/null && rc=no
check "empty backup: rc non-zero" "$rc" "yes"
check "empty backup: new file kept" "$(ls "$tmp/netplan")" "70-new.yaml"
check "empty backup: no netplan apply" "$(cat "$tmp/calls")" ""

# Case 5: no target and no --force -> usage error, nothing touched
reset
rc=yes
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --netplan-dir "$tmp/netplan" 2>/dev/null && rc=no
check "no target: rc non-zero" "$rc" "yes"
check "no target: new file kept" "$(ls "$tmp/netplan")" "70-new.yaml"

exit $fail
