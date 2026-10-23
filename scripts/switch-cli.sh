#!/usr/bin/env bash
# Run CLI lines on the Cisco SG300 switch over its old SSH, one line at a time.
#   usage: SSHPASS=<password> scripts/switch-cli.sh [--show-only] <user> <host> < lines
# Lines come on stdin, one command per line. Before each command's output the script prints
# a line "@@@ <command>". --show-only refuses any line that is not a show command, before
# connecting. The password reaches ssh only through sshpass -e (the environment), never argv.
# The firmware speaks only SHA1 key exchange, ssh-rsa host keys and CBC ciphers. They are
# allowed here, for this one connection, with -o flags. No ssh config file is read.
#
# The switch drops typed characters while it is busy, for example right after it creates
# VLANs. So each line is typed one character at a time, and Enter is pressed only when the
# switch has echoed the whole line back intact. Otherwise the line is cleared (Ctrl-U) and
# typed again, up to 3 times. After every line it waits for the prompt.
# A login that fails before the first prompt is tried again (SWITCH_CLI_TRIES, default 3,
# SWITCH_CLI_BACKOFF seconds apart, default 20): the switch can refuse new sessions for a
# while. Nothing has been sent at that point, so a retry is safe.
# copy running-config startup-config must print "Copy succeeded". A (Y/N) question after
# it, which some firmware asks, is answered Y. Any other question fails the run.
# SWITCH_KNOWN_HOSTS: the known hosts file (default build/switch/known_hosts, the file the
# network_switch role uses). The key is pinned on first use and a changed key is refused. SWITCH_CLI_TIMEOUT: seconds per command (default 60).
# Exit codes:
#   0 ok
#   2 usage, or a line refused by --show-only
#   3 the switch rejected a command, or the save did not report success
#   4 timeout
#   5 no login (connection, SSH or password) after every try
#   6 a line was not echoed back intact. It was cleared and never sent
#   7 the connection closed in the middle of the session
# Codes 3 and 6 leave config mode with end and log out before they exit.
set -euo pipefail
{ set +x; } 2>/dev/null

usage() { echo "usage: SSHPASS=<password> $0 [--show-only] <user> <host> < lines" >&2; exit 2; }

show_only=0
if [ "${1:-}" = --show-only ]; then show_only=1; shift; fi
[ $# -eq 2 ] || usage
[ -n "${SSHPASS:-}" ] || { echo "switch-cli: SSHPASS is not set" >&2; exit 2; }
for t in expect sshpass ssh; do
  command -v "$t" >/dev/null || { echo "switch-cli: $t is not installed" >&2; exit 2; }
done

lines=()
while IFS= read -r l || [ -n "$l" ]; do
  l=${l%$'\r'}
  l=$(printf '%s' "$l" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  [ -n "$l" ] || continue
  if [ "$show_only" = 1 ] && ! [[ $l =~ ^show\  ]]; then
    echo "switch-cli: --show-only refuses: $l" >&2
    exit 2
  fi
  lines+=("$l")
done
[ "${#lines[@]}" -gt 0 ] || { echo "switch-cli: no lines on stdin" >&2; exit 2; }

SWITCH_CLI_LINES=$(printf '%s\n' "${lines[@]}")
export SWITCH_CLI_LINES
if [ -z "${SWITCH_KNOWN_HOSTS:-}" ]; then
  SWITCH_KNOWN_HOSTS="$(cd "$(dirname "$0")/.." && pwd)/build/switch/known_hosts"
  mkdir -p "$(dirname "$SWITCH_KNOWN_HOSTS")"
fi
export SWITCH_KNOWN_HOSTS
export SWITCH_CLI_TIMEOUT="${SWITCH_CLI_TIMEOUT:-60}"
tries="${SWITCH_CLI_TRIES:-3}"
backoff="${SWITCH_CLI_BACKOFF:-20}"

read -r -d '' prog <<'TCL' || true
log_user 0
set user [lindex $argv 0]
set host [lindex $argv 1]
set timeout $env(SWITCH_CLI_TIMEOUT)
set known $env(SWITCH_KNOWN_HOSTS)
# The prompt: a host name, an optional (config...) mode, then # or >, at the end of output.
set prompt {(^|[\r\n])[A-Za-z0-9._-]+(\([A-Za-z0-9-]+\))?[#>] ?$}
set mode exec
set ready 0

proc fail {code msg} {
  puts stderr "switch-cli: $msg"
  catch {close}
  catch {wait}
  exit $code
}

proc lost {what} {
  global ready
  if {$ready} { fail 7 "the connection closed $what" }
  fail 5 "the connection closed $what"
}

spawn -noecho sshpass -e ssh -tt \
  -o KexAlgorithms=+diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o Ciphers=+aes128-cbc,aes256-cbc,3des-cbc \
  -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=$known -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 -o ServerAliveInterval=10 -o ServerAliveCountMax=3 \
  -o LogLevel=ERROR -F /dev/null \
  "$user@$host"

expect {
  -re $prompt {}
  timeout { fail 5 "no prompt after login" }
  eof { lost "before the prompt (login or SSH failed)" }
}
set ready 1

# Type a line one character at a time and check the echo. Enter is not pressed here.
# Returns 1 when the switch echoed the whole line, else clears it and returns 0.
proc type_line {line} {
  set got ""
  foreach ch [split $line ""] {
    send -- $ch
    expect {
      -timeout 3
      -re {.+} { append got $expect_out(buffer) }
      timeout {}
      eof { lost "while typing: $line" }
    }
  }
  expect {
    -timeout 1
    -re {.+} { append got $expect_out(buffer); exp_continue }
    timeout {}
    eof { lost "while typing: $line" }
  }
  set n [string length $line]
  set seen [string map [list "\r" "" "\n" ""] $got]
  if {[string range $seen end-[expr {$n - 1}] end] eq $line} { return 1 }
  send -- "\025"
  expect {
    -timeout 2
    -re {.+} { exp_continue }
    timeout {}
    eof { lost "while clearing: $line" }
  }
  return 0
}

# Type one line, press Enter and wait for the prompt. Sets ::out (no echo, no prompt) and
# ::mode (exec or config). Only the save command may answer a (Y/N) question, with Y.
proc run {line} {
  global prompt mode out
  set typed 0
  for {set i 0} {$i < 3 && !$typed} {incr i} { set typed [type_line $line] }
  if {!$typed} {
    puts stderr "switch-cli: the switch did not echo this line intact, it was not sent: $line"
    leave
    exit 6
  }
  send -- "\r"
  set acc ""
  set answered 0
  expect {
    -re {\(Y/N\)[^\r\n]*$} {
      append acc $expect_out(buffer)
      if {$line eq "copy running-config startup-config" && !$answered} {
        set answered 1
        send -- "Y"
        exp_continue
      }
      send -- "N"
      fail 3 "unexpected question after: $line"
    }
    -re $prompt { append acc $expect_out(buffer) }
    timeout { fail 4 "timeout after: $line" }
    eof { lost "after: $line" }
  }
  set rows [split [string map [list "\r" ""] $acc] "\n"]
  set last [lindex $rows end]
  set mode [expr {[string match "*(config*" $last] ? "config" : "exec"}]
  set out [join [lrange $rows 1 end-1] "\n"]
}

# Leave config mode, then log out and wait for the switch to close the session.
proc leave {} {
  global mode prompt
  if {$mode eq "config"} { run "end" }
  for {set i 0} {$i < 3} {incr i} {
    send -- "exit\r"
    expect {
      eof { catch {close}; catch {wait}; return }
      -re $prompt { }
      timeout { fail 4 "no clean exit" }
    }
  }
  fail 4 "the session did not end after exit"
}

run "terminal datadump"
foreach line [split [string trimright $env(SWITCH_CLI_LINES) "\n"] "\n"] {
  run $line
  puts "@@@ $line"
  if {$out ne ""} { puts $out }
  if {[regexp -nocase {%\s*(unrecognized command|invalid input|incomplete command|ambiguous command|bad parameter|wrong number|error)} $out]} {
    puts stderr "switch-cli: the switch rejected: $line"
    leave
    exit 3
  }
  if {$line eq "copy running-config startup-config" && ![regexp -nocase {copy succeeded} $out]} {
    puts stderr "switch-cli: the save did not report Copy succeeded"
    leave
    exit 3
  }
}
leave
exit 0
TCL

try=1
while :; do
  rc=0
  expect -f - "$1" "$2" <<<"$prog" || rc=$?
  if [ "$rc" -ne 5 ] || [ "$try" -ge "$tries" ]; then exit "$rc"; fi
  echo "switch-cli: no login (try $try of $tries), again in ${backoff}s" >&2
  sleep "$backoff"
  try=$((try + 1))
done
