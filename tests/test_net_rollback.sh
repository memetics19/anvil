#!/usr/bin/env bash
# Rollback script test: runs locally with stubbed ifreload/ping and temp files.
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

script=ansible/roles/pve_network/files/net-rollback.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin"
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1 (got '$2', want '$3')"; fail=1; fi; }

cat >"$tmp/bin/ifreload" <<STUB
#!/bin/sh
echo "ifreload \$*" >>"$tmp/calls"
STUB
chmod +x "$tmp/bin/ifreload"

# Case 1: target unreachable -> restore backup and reload
printf '#!/bin/sh\necho "$*" >>"%s/pingargs"\nexit 1\n' "$tmp" >"$tmp/bin/ping"; chmod +x "$tmp/bin/ping"
printf NEW >"$tmp/interfaces"; printf OLD >"$tmp/backup"; chmod 600 "$tmp/backup"; chmod 644 "$tmp/interfaces"; : >"$tmp/calls"
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --wait 1 --target 192.0.2.10 --interfaces-file "$tmp/interfaces"
check "unreachable: rc" "$?" "0"
check "unreachable: file restored" "$(cat "$tmp/interfaces")" "OLD"
check "unreachable: target reached ping" "$(grep -c -- '192.0.2.10' "$tmp/pingargs")" "1"
mode=$(stat -c %a "$tmp/interfaces" 2>/dev/null || stat -f %Lp "$tmp/interfaces")  # GNU first: GNU `stat -f` means filesystem status
check "unreachable: restored mode 644" "$mode" "644"
check "unreachable: ifreload -a called" "$(cat "$tmp/calls")" "ifreload -a"

# Case 2: target reachable -> leave the new file alone
printf '#!/bin/sh\nexit 0\n' >"$tmp/bin/ping"
printf NEW >"$tmp/interfaces"; : >"$tmp/calls"
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --wait 0 --target 192.0.2.10 --interfaces-file "$tmp/interfaces"
check "reachable: file untouched" "$(cat "$tmp/interfaces")" "NEW"
check "reachable: no ifreload" "$(cat "$tmp/calls")" ""

# Case 3: missing backup -> non-zero, file untouched
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/ping"
rc=yes
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/nope" --wait 0 --target 192.0.2.10 --interfaces-file "$tmp/interfaces" 2>/dev/null && rc=no
check "missing backup: rc non-zero" "$rc" "yes"
check "missing backup: file untouched" "$(cat "$tmp/interfaces")" "NEW"

# Case 4: restore fails (interfaces path is a missing directory) -> abort, no ifreload
: >"$tmp/calls"; printf OLD >"$tmp/backup"
rc=0
PATH="$tmp/bin:$PATH" bash "$script" "$tmp/backup" --wait 0 --target 192.0.2.10 --interfaces-file "$tmp/nodir/interfaces" 2>/dev/null || rc=$?
check "cp failure: rc non-zero" "$([ "$rc" -ne 0 ] && echo yes)" "yes"
check "cp failure: no ifreload" "$(cat "$tmp/calls")" ""

exit $fail
