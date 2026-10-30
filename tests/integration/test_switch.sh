#!/usr/bin/env bash
# The switch role's command plan (ansible/roles/network_switch/filter_plugins) and the SSH
# helper (scripts/switch-cli.sh), run locally. The plan is rendered from example show
# output: it must name only the listed ports, never a keep port, and be empty once the
# switch matches. The helper runs against a fake switch (a stub sshpass on PATH).
# Uses documentation-range addresses only.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  got:  $2"; echo "  want: $3"; fail=1; fi; }

# --- plan -------------------------------------------------------------------------------------
python3 - ansible/roles/network_switch/filter_plugins/network_switch.py <<'PY' || fail=1
import importlib.util, re, sys
spec = importlib.util.spec_from_file_location("ns", sys.argv[1])
ns = importlib.util.module_from_spec(spec); spec.loader.exec_module(ns)

def switchport(port, members):
    rows = "\n".join(" %d   %d   %s   %s" % (v, v, e, "System" if v == 1 else "Static") for v, e in members)
    return ("Port : %s\nPort Mode: Trunk\nGvrp Status: disabled\nIngress Filtering: true\n"
            "Acceptable Frame Type: admitAll\nIngress UnTagged VLAN ( NATIVE ): 1\n \nPort is member in: \n \n"
            "Vlan  Name  Egress rule Port Membership Type \n---- ---- ----------- ---------\n%s\n \n"
            "Forbidden VLANS: \nVlan  Name \n---- ----\n" % (port, rows))

def protected(on):
    return "\nInterface     State     \n--------- ------------- \n" + "\n".join(
        "  gi%d     %s  " % (i, "Protected" if "gi%d" % i in on else "Unprotected") for i in range(1, 53))

VLAN1 = (" Vlan       Name                   Ports                Type     Authorization \n"
         "---- ----------------- --------------------------- ------------ ------------- \n"
         " 1           1                gi1-52,Po1-8           Default      Required    \n")
VLANS = VLAN1 + (" 10       servers           gi10                  Static       Required\n"
                 " 20       cameras           gi10                  Static       Required\n"
                 " 30       personal          gi10                  Static       Required\n")
vlans = [{"name": "servers", "tag": 10}, {"name": "cameras", "tag": 20}, {"name": "personal", "tag": 30}]
ports = {"gi10": ["trunk", "protected"], "gi11": "protected"}
keep = ["gi1", "gi2"]
fails = 0

def ok(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

def state(vlan_text, members10, prot):
    return {"show vlan": vlan_text, "show interfaces protected-ports": protected(prot),
            "show interfaces switchport gi10": switchport("gi10", members10),
            "show interfaces switchport gi11": switchport("gi11", [(1, "Untagged")])}

ok("read commands", ns.switch_read_commands(ports) == [
    "show vlan", "show interfaces protected-ports",
    "show interfaces switchport gi10", "show interfaces switchport gi11"])

today = state(VLAN1, [(1, "Untagged")], [])
plan = ns.switch_plan(today, ports, vlans, 1, keep)
want = ["configure terminal",
        "vlan database", "vlan 10,20,30", "exit",
        "interface vlan 10", "name servers", "exit",
        "interface vlan 20", "name cameras", "exit",
        "interface vlan 30", "name personal", "exit",
        "interface gi10", "switchport trunk allowed vlan add 10,20,30", "switchport protected-port", "exit",
        "interface gi11", "switchport protected-port", "exit",
        "end"]
ok("plan from today's state", plan == want)
if plan != want:
    print("\n".join(plan))
named = set(re.findall(r"\bgi\d+\b", "\n".join(plan)))
ok("plan names only the listed ports", named <= set(ports))
ok("plan never names a keep port", not named & set(keep))
ok("trunk keeps native VLAN 1 (no mode or native change)",
   not [l for l in plan if "mode" in l or "native" in l])

done = state(VLANS, [(1, "Untagged"), (10, "Tagged"), (20, "Tagged"), (30, "Tagged")], ["gi10", "gi11"])
ok("empty plan once the switch matches", ns.switch_plan(done, ports, vlans, 1, keep) == [])

half = state(VLANS, [(1, "Untagged"), (10, "Tagged")], ["gi10"])
ok("only the missing pieces", ns.switch_plan(half, ports, vlans, 1, keep) == [
    "configure terminal", "interface gi10", "switchport trunk allowed vlan add 20,30", "exit",
    "interface gi11", "switchport protected-port", "exit", "end"])

ok("no VLANs without a trunk port",
   ns.switch_plan(today, {"gi11": ["protected"]}, vlans, 1, keep)
   == ["configure terminal", "interface gi11", "switchport protected-port", "exit", "end"])

def rejects(name, fn):
    try:
        fn()
    except ns.AnsibleFilterError:
        ok("rejects " + name, True)
    else:
        ok("rejects " + name, False)

rejects("a keep port in ports", lambda: ns.switch_plan(today, dict(ports, gi1="protected"), vlans, 1, keep))
rejects("a keep port that is protected", lambda: ns.switch_plan(state(VLAN1, [(1, "Untagged")], ["gi2"]), ports, vlans, 1, keep))
rejects("an unknown role", lambda: ns.switch_plan(today, {"gi10": ["access"]}, vlans, 1, keep))
rejects("a bad port name", lambda: ns.switch_plan(today, {"Gi1/0/10": ["trunk"]}, vlans, 1, keep))
rejects("native VLAN 1 tagged", lambda: ns.switch_plan(
    state(VLAN1, [(1, "Tagged")], []), ports, vlans, 1, keep))
rejects("output it cannot read", lambda: ns.switch_plan(dict(today, **{"show interfaces protected-ports": "?"}), ports, vlans, 1, keep))

# DHCP snooping: the output of show ip dhcp snooping, off and on.
def snooping(enabled, vlans, trusted):
    return ("DHCP snooping is %s\nDHCP snooping is configured on following VLANs: %s\n"
            "DHCP snooping database is Disabled\nRelay agent Information option 82 is Disabled\n"
            "Option 82 on untrusted port is forbidden\nVerification of hwaddr field is Enabled\n"
            "DHCP snooping file update frequency is configured to: 1200 seconds\n Interface    Trusted    \n"
            "----------- ------------ \n%s" % ("Enabled" if enabled else "Disabled", vlans,
                                               "".join("  %s         Yes     \n" % p for p in trusted)))

snoop = {"trusted": ["gi2", "gi10"]}
ok("read commands with snooping", ns.switch_read_commands(ports, snoop)[-1] == "show ip dhcp snooping")
off = dict(done, **{"show ip dhcp snooping": snooping(False, "", [])})
plan = ns.switch_plan(off, ports, vlans, 1, keep, snoop)
ok("snooping: trust first, then the VLAN, then switch it on", plan == [
    "configure terminal",
    "interface gi2", "ip dhcp snooping trust", "exit",
    "interface gi10", "ip dhcp snooping trust", "exit",
    "ip dhcp snooping vlan 1", "ip dhcp snooping", "end"])
ok("snooping may trust a keep port (the router uplink)", "interface gi2" in plan)
on = dict(done, **{"show ip dhcp snooping": snooping(True, "1", ["gi2", "gi10"])})
ok("snooping: empty plan once it matches", ns.switch_plan(on, ports, vlans, 1, keep, snoop) == [])
half_on = dict(done, **{"show ip dhcp snooping": snooping(True, "1, 5-6", ["gi10"])})
ok("snooping: only the missing trust", ns.switch_plan(half_on, ports, vlans, 1, keep, snoop) == [
    "configure terminal", "interface gi2", "ip dhcp snooping trust", "exit", "end"])
ok("snooping absent: nothing planned for it", ns.switch_plan(done, ports, vlans, 1, keep, None) == [])
rejects("snooping with no trusted port", lambda: ns.switch_plan(off, ports, vlans, 1, keep, {"trusted": []}))
rejects("snooping with a bad port name", lambda: ns.switch_plan(off, ports, vlans, 1, keep, {"trusted": ["Gi1/0/2"]}))
rejects("snooping output it cannot read", lambda: ns.switch_plan(dict(done, **{"show ip dhcp snooping": "?"}), ports, vlans, 1, keep, snoop))

out = "@@@ show vlan\n" + VLAN1 + "@@@ show interfaces protected-ports\n" + protected([])
ok("switch_state splits by command", sorted(ns.switch_state(out)) == ["show interfaces protected-ports", "show vlan"])
sys.exit(1 if fails else 0)
PY

# --- switch-cli.sh against a fake switch --------------------------------------------------------
# The fake echoes each typed character itself, so it can drop one (FAKE_DROP=<n>: the n-th
# character typed after login). Ctrl-U clears the line. FAKE_REFUSE=<n> refuses the first n
# logins. FAKE_COPY: ask (a Y/N question, then success), plain (success, no question) or
# fail (no success line).
mkdir "$tmp/bin"
cat >"$tmp/bin/sshpass" <<'STUB'
#!/usr/bin/env bash
log=${FAKE_LOG:?}
printf '%s\n' "$@" >"$log.argv"
[ "${SSHPASS:-}" = s3cret-pw ] && echo yes >"$log.env"
n=$(( $(cat "$log.logins" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$log.logins"
[ "$n" -le "${FAKE_REFUSE:-0}" ] && exit 255
stty -echo -icanon min 1 2>/dev/null
mode=""
p() { printf '\r\nsw%s#' "$mode"; }
printf '\r\nbanner\r\n'; p
buf=""; typed=0
while IFS= read -r -s -n1 -d '' c; do
  case "$c" in
    $'\r'|$'\n') ;;
    $'\025') buf=""; printf '\r\033[Ksw%s#' "$mode"; continue ;;
    *) typed=$((typed + 1))
       [ "$typed" = "${FAKE_DROP:-0}" ] && continue
       buf+=$c; printf '%s' "$c"; continue ;;
  esac
  line=$buf; buf=""
  printf '\r\n'
  echo "$line" >>"$log"
  case "$line" in
    "terminal datadump") ;;
    "show vlan") printf '\r\n 1  1  gi1-52  Default' ;;
    "configure terminal") mode="(config)" ;;
    "interface "*) mode="(config-if)" ;;
    "switchport protected-port") ;;
    "end") mode="" ;;
    "copy running-config startup-config")
      case "${FAKE_COPY:-plain}" in
        ask) printf '\r\nOverwrite file [startup-config].... (Y/N)[N] ?'; IFS= read -r -s -n1 -d '' a
             echo "answer:$a" >>"$log"; printf '\r\nCopy succeeded' ;;
        plain) printf '\r\nCopy succeeded' ;;
        *) printf '\r\nCopy failed' ;;
      esac ;;
    "exit") case "$mode" in "") exit 0 ;; "(config)") mode="" ;; *) mode="(config)" ;; esac ;;
    *) printf '\r\n%% Unrecognized command' ;;
  esac
  p
done
STUB
chmod +x "$tmp/bin/sshpass"
export FAKE_LOG="$tmp/log"
cli() { rm -f "$tmp/log"*; PATH="$tmp/bin:$PATH" SSHPASS=s3cret-pw SWITCH_CLI_TIMEOUT=10 SWITCH_CLI_BACKOFF=0 scripts/switch-cli.sh "$@" >"$tmp/out" 2>"$tmp/err"; }

printf 'show vlan\n' | cli --show-only admin 192.0.2.24
check "show: rc" "$?" 0
check "show: output under its marker" "$(tr -d '\r' <"$tmp/out" | sed -n '1p;$p')" "@@@ show vlan
 1  1  gi1-52  Default"
check "show: datadump first, exit last" "$(cat "$tmp/log")" "terminal datadump
show vlan
exit"
check "password only in the environment" "$(cat "$tmp/log.env"; grep -c s3cret-pw "$tmp/log.argv")" "yes
0"
check "legacy algorithms on the command line" \
  "$(grep -c -e 'KexAlgorithms=+diffie-hellman-group-exchange-sha1' -e 'Ciphers=+aes128-cbc' -e 'HostKeyAlgorithms=+ssh-rsa' "$tmp/log.argv")" 3

printf 'show vlan\nconfigure terminal\n' | cli --show-only admin 192.0.2.24
check "show-only: refuses a config line" "$?" 2
check "show-only: never connects" "$(cat "$tmp/log" 2>/dev/null)" ""

printf 'configure terminal\ninterface gi10\nswitchport protected-port\nexit\n' | cli admin 192.0.2.24
check "config: rc" "$?" 0
check "config: leaves config mode with end, then exit" "$(tail -2 "$tmp/log")" "end
exit"

# 17 characters of terminal datadump, then the 3rd of configure terminal is dropped.
printf 'configure terminal\ninterface gi10\n' | FAKE_DROP=20 cli admin 192.0.2.24
check "dropped character: rc" "$?" 0
check "dropped character: the line is retyped, never sent broken" "$(sed -n 2p "$tmp/log")" "configure terminal"

printf 'configure terminal\nbogus\nshow vlan\n' | cli admin 192.0.2.24
check "error: rc 3" "$?" 3
check "error: stops, ends config mode, exits" "$(cat "$tmp/log")" "terminal datadump
configure terminal
bogus
end
exit"

printf 'copy running-config startup-config\n' | FAKE_COPY=plain cli admin 192.0.2.24
check "save without a question: rc" "$?" 0
printf 'copy running-config startup-config\n' | FAKE_COPY=ask cli admin 192.0.2.24
check "save with a question: rc" "$?" 0
check "save with a question: answers Y" "$(grep answer "$tmp/log")" "answer:Y"
printf 'copy running-config startup-config\n' | FAKE_COPY=fail cli admin 192.0.2.24
check "save without Copy succeeded: rc 3" "$?" 3

printf 'show vlan\n' | FAKE_REFUSE=2 cli --show-only admin 192.0.2.24
check "login refused twice: third try works" "$?:$(cat "$tmp/log.logins")" "0:3"
printf 'show vlan\n' | FAKE_REFUSE=9 cli --show-only admin 192.0.2.24
check "login refused every time: rc 5 after 3 tries" "$?:$(cat "$tmp/log.logins")" "5:3"

printf 'show vlan\n' | env -u SSHPASS PATH="$tmp/bin:$PATH" scripts/switch-cli.sh admin 192.0.2.24 >/dev/null 2>&1
check "no SSHPASS: refused" "$?" 2

# A known hosts file that cannot hold the key turns pinning off: accept-new would take any
# key every time. Each is refused before connecting.
mkdir "$tmp/ro"
chmod a-w "$tmp/ro"
for kh in /dev/null none "$tmp" "$tmp/missing/known_hosts" "$tmp/ro/known_hosts"; do
  [ "$kh" = "$tmp/ro/known_hosts" ] && [ "$(id -u)" = 0 ] && continue
  printf 'show vlan\n' | SWITCH_KNOWN_HOSTS=$kh cli --show-only admin 192.0.2.24
  check "known hosts ${kh/#"$tmp"/<tmp>}: refused, never connects" "$?:$(cat "$tmp/log.logins" 2>/dev/null)" "2:"
  check "known hosts ${kh/#"$tmp"/<tmp>}: says why" "$(grep -c 'pinning' "$tmp/err")" 1
done
chmod u+w "$tmp/ro"
printf 'show vlan\n' | SWITCH_KNOWN_HOSTS="$tmp/known_hosts" cli --show-only admin 192.0.2.24
check "known hosts: a new file in a writable directory is fine" "$?" 0

exit "$fail"
