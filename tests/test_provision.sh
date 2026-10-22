#!/usr/bin/env bash
# scripts/provision.py, run locally on site/site.example.yml (documentation addresses only):
# the answer file has the right fields and only a password hash, a disk is required and a
# filter may not match any disk, and the guard refuses the current server.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

python3 - scripts/provision.py site/site.example.yml <<'PY'
import copy, importlib.util, subprocess, sys, tomllib, yaml
spec = importlib.util.spec_from_file_location("provision", sys.argv[1])
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
with open(sys.argv[2]) as f:
    SITE = yaml.safe_load(f)["site"]
fails = 0

def ok(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

def refused(name, fn, want=""):
    try:
        fn()
    except p.Refused as e:
        ok(name, want in str(e))
        return
    ok(name + " (not refused)", False)

def site_with(**machine):
    s = copy.deepcopy(SITE)
    s["provision"]["machines"]["pve2"].update(machine)
    return s

KEY = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyExampleOnlyExampleOnlyExampl test"]
plain = "test-only-" + "plaintext-value"
h = p.hash_password(plain)

# --- answer file --------------------------------------------------------------------------------
text = p.answer(SITE, "pve2", h, KEY)
a = tomllib.loads(text)
g = a["global"]
ok("keyboard, country, timezone", (g["keyboard"], g["country"], g["timezone"]) == ("en-us", "us", "UTC"))
ok("fqdn from hostname and domain", g["fqdn"] == "pve2.example.com")
ok("mailto from site.email", g["mailto"] == "admin@example.com")
ok("operator SSH key", g["root_ssh_keys"] == KEY)
ok("hash only, no plaintext", g["root_password_hashed"] == h and h.startswith("$6$") and plain not in text and "root_password =" not in text)
salt = h.split("$")[2]
again = subprocess.run([p.openssl_bin(), "passwd", "-6", "-salt", salt, "-stdin"], input=plain + "\n", capture_output=True, text=True).stdout.strip()
ok("the hash matches the password", again == h)
ok("power off at the end", g["reboot_mode"] == "power-off")
n = a["network"]
ok("static network on the NIC with the MAC", n["source"] == "from-answer" and n["cidr"] == "192.0.2.12/24"
   and n["gateway"] == "192.0.2.1" and n["dns"] == "192.0.2.1" and n["filter"] == {"ID_NET_NAME_MAC": "*020000000020"})
d = a["disk-setup"]
ok("one disk filter -> ext4", d["filesystem"] == "ext4" and d["filter"] == {"ID_SERIAL": "EXAMPLE-DISK-0"} and d["filter_match"] == "all")

a = tomllib.loads(p.answer(site_with(disks=["sda", "sdb"]), "pve2", h, KEY))
ok("two disk names -> ZFS mirror", a["disk-setup"] == {"filesystem": "zfs", "zfs": {"raid": "raid1"}, "disk_list": ["sda", "sdb"]})
a = tomllib.loads(p.answer(site_with(disks=["nvme0n1"]), "pve2", h, KEY))
ok("one disk name -> ext4", a["disk-setup"] == {"filesystem": "ext4", "disk_list": ["nvme0n1"]})
a = tomllib.loads(p.answer(site_with(network="dhcp"), "pve2", h, KEY))
ok("network dhcp", a["network"] == {"source": "from-dhcp"})

s = site_with(); del s["provision"]["machines"]["pve2"]["disks"]
refused("no disks refused", lambda: p.answer(s, "pve2", h, KEY), "disks")
refused("empty disk list refused", lambda: p.answer(site_with(disks=[]), "pve2", h, KEY), "disks")
refused("three disks refused", lambda: p.answer(site_with(disks=["sda", "sdb", "sdc"]), "pve2", h, KEY), "disks")
refused("wildcard-only filter refused", lambda: p.answer(site_with(disks=[{"ID_MODEL": "*"}]), "pve2", h, KEY), "matches any disk")
refused("empty filter refused", lambda: p.answer(site_with(disks=[{}]), "pve2", h, KEY))
refused("mirror by filter refused", lambda: p.answer(site_with(disks=[{"ID_MODEL": "X*"}, {"ID_MODEL": "Y*"}]), "pve2", h, KEY), "two disk names")
refused("same disk twice refused", lambda: p.answer(site_with(disks=["sda", "sda"]), "pve2", h, KEY), "same")
refused("plaintext instead of a hash refused", lambda: p.answer(SITE, "pve2", plain, KEY), "hash")
refused("no SSH key refused", lambda: p.answer(SITE, "pve2", h, []), "SSH")
refused("static network without a MAC refused", lambda: p.answer(site_with(network={"cidr": "192.0.2.12/24", "gateway": "192.0.2.1", "dns": "192.0.2.1"}), "pve2", h, KEY), "mac")
refused("gateway outside the network refused", lambda: p.answer(site_with(network={"cidr": "192.0.2.12/24", "gateway": "198.51.100.1", "dns": "192.0.2.1", "mac": "02:00:00:00:00:20"}), "pve2", h, KEY), "gateway")
refused("unknown machine refused", lambda: p.answer(SITE, "nope", h, KEY), "no site.provision")
refused("media redfish without a Redfish BMC refused", lambda: p.machine(site_with(bmc={"type": "ipmi", "address": "192.0.2.124"}), "pve2"), "media redfish")

# --- the guard against the current server -------------------------------------------------------
def guard(s):
    return p.static_guard(s, "pve2", p.machine(s, "pve2"))

guard(SITE); ok("the example target passes", True)
refused("current BMC address refused", lambda: guard(site_with(bmc={"type": "redfish", "address": SITE["pve"]["idrac_ip"]})), "current server")
refused("current host address as BMC refused", lambda: guard(site_with(bmc={"type": "ipmi", "address": SITE["pve"]["ip"]}, media="manual")), "current server")
s = site_with(bmc={"type": "redfish", "address": "192.0.2.200"}); s["provision"]["refuse"]["bmc_addresses"] = ["192.0.2.200"]
refused("listed BMC address refused", lambda: guard(s), "current server")
refused("current NIC MAC refused", lambda: guard(site_with(network=dict(SITE["provision"]["machines"]["pve2"]["network"], mac="02:00:00:00:00:11"))), "NICs")
refused("current NIC MAC refused, other case", lambda: guard(site_with(network=dict(SITE["provision"]["machines"]["pve2"]["network"], mac="02-00-00-00-00-10"))), "NICs")
refused("current serial refused", lambda: guard(site_with(serial="example0")), "serial")
refused("address in use refused", lambda: guard(site_with(network=dict(SITE["provision"]["machines"]["pve2"]["network"], cidr="192.0.2.121/24"))), "in use")
s = copy.deepcopy(SITE); s["provision"]["refuse"]["serials"] = []
refused("empty serial refuse list refuses everything", lambda: guard(s), "refuse needs")
s = copy.deepcopy(SITE); del s["provision"]["refuse"]
refused("no refuse list refuses everything", lambda: guard(s), "refuse needs")
m = p.machine(SITE, "pve2")
refused("BMC reporting the current serial refused", lambda: p.live_guard(SITE, "pve2", m, ["EXAMPLE2", "Example0"]), "current server")
refused("BMC not reporting the expected serial refused", lambda: p.live_guard(SITE, "pve2", m, ["OTHER"]), "expected serial")
p.live_guard(SITE, "pve2", m, ["EXAMPLE2", None]); ok("BMC reporting the expected serial passes", True)

sys.exit(1 if fails else 0)
PY
rc=$?

# The CLI exits 3 on a refusal and never echoes the password.
out=$(printf 'test-only-cli-value\n' | PROVISION_SITE_FILE=site/site.example.yml python3 scripts/provision.py answer --name pve2 --ssh-key /dev/null 2>&1)
code=$?
if [ "$code" = 3 ] && ! grep -q test-only-cli-value <<<"$out"; then echo "ok   CLI refuses an empty key file, no echo"; else echo "FAIL CLI refusal ($code)"; rc=1; fi

exit "$rc"
