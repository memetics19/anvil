#!/usr/bin/env bash
# Pi-hole's regex block list (pihole_deny_regex): every entry is a valid extended regex that
# matches its domain and subdomains and nothing that only ends alike. TP-Link's cloud is
# blocked, the cameras' time servers are not. Needs no lab.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
python3 - <<'PY' || fail=1
import re, sys, yaml
d = yaml.safe_load(open("ansible/roles/pihole/defaults/main.yml"))
rx = [e["regex"] for e in d["pihole_deny_regex"]]
bad = 0
def check(name, ok_):
    global bad
    print(("ok   " if ok_ else "FAIL ") + name)
    bad += not ok_
for r in rx:
    try:
        re.compile(r)
        check(f"{r} compiles", True)
    except re.error as e:
        check(f"{r} compiles ({e})", False)
blocked = lambda dom: any(re.search(r, dom) for r in rx)
for dom in ["stun.tplinkcloud.com", "n-aps1-da.tplinkcloud.com", "ain1-device-cloudgateway.iot.i.tplinknbu.com",
            "aps1-device-tapo-care.i.tplinknbu.com", "tplinkra.com"]:
    check(f"blocked: {dom}", blocked(dom))
for dom in ["nz.pool.ntp.org", "time.windows.com", "mytplinkcloud.com.example", "nottplinkcloud.com"]:
    check(f"not blocked: {dom}", not blocked(dom))
sys.exit(1 if bad else 0)
PY
[ "$fail" = 0 ] && echo "PASS: pihole deny regex"
exit "$fail"
