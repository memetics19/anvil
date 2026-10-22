#!/usr/bin/env bash
# Run CLI lines on the Cisco SG300 switch over its old SSH, one line at a time.
#   usage: SSHPASS=<password> scripts/switch-cli.sh [--show-only] <user> <host> < lines
# Lines come on stdin, one command per line. Before each command's output the script prints
# a line "@@@ <command>". It waits for the switch prompt after every line, so nothing is
# typed ahead. --show-only refuses any line that is not a show command, before connecting.
# The password reaches ssh only through sshpass -e (the environment), never argv.
# The firmware speaks only SHA1 key exchange, ssh-rsa host keys and CBC ciphers. They are
# allowed here, for this one connection, with -o flags. No ssh config file is read.
# SWITCH_KNOWN_HOSTS: the known hosts file (default /dev/null, no host key check). A real
# file pins the key on first use. SWITCH_CLI_TIMEOUT: seconds per command (default 60).
# Exit codes: 0 ok, 2 usage or refused line, 3 the switch reported an error (the session
# leaves config mode with end first), 4 timeout, 5 connection or login failed.
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
export SWITCH_KNOWN_HOSTS="${SWITCH_KNOWN_HOSTS:-/dev/null}"
export SWITCH_CLI_TIMEOUT="${SWITCH_CLI_TIMEOUT:-60}"

exec expect -f - "$1" "$2" <<'TCL'
log_user 0
set user [lindex $argv 0]
set host [lindex $argv 1]
set timeout $env(SWITCH_CLI_TIMEOUT)
set known $env(SWITCH_KNOWN_HOSTS)
set strict [expr {$known eq "/dev/null" ? "no" : "accept-new"}]
# The prompt: a host name, an optional (config...) mode, then # or >, at the end of output.
set prompt {(^|[\r\n])[A-Za-z0-9._-]+(\([A-Za-z0-9-]+\))?[#>] ?$}
set send_slow {16 .005}
set mode exec

proc fail {code msg} {
  puts stderr "switch-cli: $msg"
  catch {close}
  catch {wait}
  exit $code
}

spawn -noecho sshpass -e ssh -tt \
  -o KexAlgorithms=+diffie-hellman-group-exchange-sha1,diffie-hellman-group1-sha1 \
  -o HostKeyAlgorithms=+ssh-rsa -o PubkeyAcceptedAlgorithms=+ssh-rsa \
  -o Ciphers=+aes128-cbc,aes256-cbc,3des-cbc \
  -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
  -o NumberOfPasswordPrompts=1 -o StrictHostKeyChecking=$strict \
  -o UserKnownHostsFile=$known -o GlobalKnownHostsFile=/dev/null \
  -o ConnectTimeout=10 -o LogLevel=ERROR -F /dev/null \
  "$user@$host"

expect {
  -re $prompt {}
  timeout { fail 4 "no prompt after login" }
  eof { fail 5 "the connection closed before the prompt (login or SSH failed)" }
}

# Send one line and wait for the prompt. Sets ::out to the output (no echo, no prompt) and
# ::mode to exec or config. Only the save command may answer a (Y/N) question, with Y.
proc run {line} {
  global prompt mode out
  send -s -- "$line\r"
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
    eof { fail 5 "the connection closed after: $line" }
  }
  set rows [split [string map [list "\r" ""] $acc] "\n"]
  set last [lindex $rows end]
  set mode [expr {[string match "*(config*" $last] ? "config" : "exec"}]
  set out [join [lrange $rows 1 end-1] "\n"]
}

proc leave {} {
  global mode prompt
  if {$mode eq "config"} { run "end" }
  for {set i 0} {$i < 3} {incr i} {
    send -- "exit\r"
    expect {
      eof { catch {wait}; return }
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
}
leave
exit 0
TCL
