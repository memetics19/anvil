#!/usr/bin/env bash
# scripts/provision.py, run locally on site/site.example.yml (documentation addresses only):
# the answer file has the right fields and only a password hash, a disk is required and a
# filter may not match any disk, and the guard refuses the current server. make provision's
# dry run and install run against a fake Redfish BMC on 127.0.0.1: the dry run only reads,
# the current server is refused before any request, and the ISO is served with byte ranges.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
# No scripts/__pycache__: the media test scans scripts/.
export PYTHONDONTWRITEBYTECODE=1

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

# --- make provision against a fake Redfish BMC ---------------------------------------------------
python3 - scripts/provision.py site/site.example.yml <<'PY2' || rc=1
import base64, copy, http.server, importlib.util, json, os, subprocess, sys, tempfile, threading, urllib.request, yaml
spec = importlib.util.spec_from_file_location("provision", sys.argv[1])
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
with open(sys.argv[2]) as f:
    SITE = yaml.safe_load(f)["site"]
fails = 0
def ok(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

USER, PW = "bmc-user", "test-only-" + "bmc-secret"
AUTH = "Basic " + base64.b64encode(f"{USER}:{PW}".encode()).decode()
CD = "/redfish/v1/Managers/1/VirtualMedia/CD"

class Fake:
    def reset(self, power="Off", serial="EXAMPLE2", insert=True):
        self.power, self.serial, self.insert, self.inserted = power, serial, insert, False
        self.log, self.fetched, self.system_gets = [], None, 0

def system():
    F.system_gets += 1
    if F.power == "On" and F.fetched and F.system_gets > 3:
        F.power = "Off"   # the installer is done and powers off
    return {"PowerState": F.power, "SerialNumber": F.serial, "SKU": "",
            "Boot": {"BootSourceOverrideTarget@Redfish.AllowableValues": ["Pxe", "Cd", "Hdd"]},
            "Actions": {"#ComputerSystem.Reset": {"target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
                                                   "ResetType@Redfish.AllowableValues": ["On", "ForceOff"]}},
            "Links": {"ManagedBy": [{"@odata.id": "/redfish/v1/Managers/1"}]}}

def cd():
    d = {"MediaTypes": ["CD", "DVD"], "Inserted": F.inserted}
    if F.insert:
        d["Actions"] = {"#VirtualMedia.InsertMedia": {"target": CD + "/Actions/VirtualMedia.InsertMedia"},
                        "#VirtualMedia.EjectMedia": {"target": CD + "/Actions/VirtualMedia.EjectMedia"}}
    return d

GETS = {"/redfish/v1": lambda: {"Systems": {"@odata.id": "/redfish/v1/Systems"}, "Managers": {"@odata.id": "/redfish/v1/Managers"}},
        "/redfish/v1/Systems": lambda: {"Members": [{"@odata.id": "/redfish/v1/Systems/1"}]},
        "/redfish/v1/Systems/1": system,
        "/redfish/v1/Managers/1": lambda: {"VirtualMedia": {"@odata.id": "/redfish/v1/Managers/1/VirtualMedia"}},
        "/redfish/v1/Managers/1/VirtualMedia": lambda: {"Members": [{"@odata.id": "/redfish/v1/Managers/1/VirtualMedia/RemovableDisk"}, {"@odata.id": CD}]},
        "/redfish/v1/Managers/1/VirtualMedia/RemovableDisk": lambda: {"MediaTypes": ["USBStick"]},
        CD: cd}

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, body=None):
        data = json.dumps(body or {}).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(n) or b"null")
        F.log.append((method, self.path, body))
        if self.headers.get("Authorization") != AUTH:
            return self.reply(401)
        if method == "GET":
            return self.reply(200, GETS[self.path]()) if self.path in GETS else self.reply(404)
        if self.path.endswith("VirtualMedia.InsertMedia"):
            req = urllib.request.Request(body["Image"], headers={"Range": "bytes=10-19"})
            with urllib.request.urlopen(req) as r:
                F.fetched = (r.status, r.headers.get("Content-Range"), r.read())
            F.inserted = True
        elif self.path.endswith("VirtualMedia.EjectMedia"):
            F.inserted = False
        elif self.path.endswith("ComputerSystem.Reset") and body.get("ResetType") == "On":
            F.power = "On"; F.system_gets = 0
        self.reply(204)
    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")

F = Fake(); F.reset()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
tmp = tempfile.mkdtemp()
creds = os.path.join(tmp, "creds.json")
with open(creds, "w") as f:
    json.dump({"username": USER, "password": PW}, f)
isodir = os.path.join(tmp, "iso"); os.mkdir(isodir)
ISO = bytes(range(256)) * 4096

def site_file(**machine):
    s = copy.deepcopy(SITE)
    s["provision"]["machines"]["pve2"].update({"bmc": {"type": "redfish", "address": "127.0.0.1"}}, **machine)
    path = os.path.join(tmp, "site.json")
    with open(path, "w") as f:
        json.dump({"site": s}, f)
    return path

def cli(site, *extra, creds_file=creds):
    env = dict(os.environ, PROVISION_SITE_FILE=site, PROVISION_BMC_CREDENTIALS_FILE=creds_file,
               PROVISION_TEST_REDFISH_URL=f"http://127.0.0.1:{srv.server_address[1]}",
               PROVISION_ISO_DIR=isodir, PROVISION_TEST_POLL_SCALE="0.01")
    r = subprocess.run([sys.executable, sys.argv[1], "run", "--name", "pve2", *extra], env=env, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr

def _raises(fn):
    try:
        fn()
    except p.Refused as e:
        return e
    return None

def site_with_m(s, **machine):
    s = copy.deepcopy(s)
    s["provision"]["machines"]["pve2"].update(machine)
    return s

def writes():
    return [(m, path, b) for m, path, b in F.log if m != "GET"]

# dry run: reads, then the plan in a fixed shape, no secrets, no writes
F.reset()
code, out, err = cli(site_file())
lines = out.splitlines()
ok("dry run exits 0", code == 0)
ok("dry run header", lines[0] == "provision pve2: dry run, nothing changes. Apply with -e provision_confirm=pve2")
ok("dry run guard line", lines[1].startswith("guard: ok"))
ok("dry run reads are GETs", [l for l in lines if l.startswith("read: GET ")][:3] == ["read: GET /redfish/v1", "read: GET /redfish/v1/Systems", "read: GET /redfish/v1/Systems/1"])
plan = [l for l in lines if l.startswith("plan: ")]
want = ["plan: serve " , "plan: POST " + CD + "/Actions/VirtualMedia.InsertMedia {\"Image\": \"http://<this Mac's LAN address>:<port>/<random>/pve2.iso\", \"Inserted\": true, \"WriteProtected\": true}",
        'plan: PATCH /redfish/v1/Systems/1 {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Cd"}}',
        'plan: POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset {"ResetType": "On"}',
        "plan: wait for the installer to power the server off (up to 90 min)",
        "plan: POST " + CD + "/Actions/VirtualMedia.EjectMedia {}",
        "plan: stop serving and delete ",
        'plan: POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset {"ResetType": "On"}',
        "plan: wait for SSH on 192.0.2.12:22"]
ok("dry run plan shape", len(plan) == len(want) and all(a.startswith(b) for a, b in zip(plan, want)))
ok("dry run sends only GETs", F.log and not writes())
ok("dry run prints no password", PW not in out + err and "bmc-user" not in out + err)

# the current server: refused before any request
F.reset()
code, out, err = cli(site_file(bmc={"type": "redfish", "address": SITE["pve"]["idrac_ip"]}))
ok("current server refused (exit 3)", code == 3 and "refused" in err and "current server" in err)
ok("current server: no request sent", F.log == [])
F.reset()
code, out, err = cli(site_file(network=dict(SITE["provision"]["machines"]["pve2"]["network"], mac=SITE["provision"]["refuse"]["macs"][0])))
ok("current server MAC refused, no request", code == 3 and F.log == [])
F.reset(serial="EXAMPLE0")
code, out, err = cli(site_file())
ok("BMC reporting the current serial refused, reads only", code == 3 and "current server" in err and not writes())

# no standard InsertMedia: refused cleanly
F.reset(insert=False)
code, out, err = cli(site_file())
ok("no InsertMedia refused", code == 3 and "InsertMedia" in err and not writes())
F.reset(insert=False)
code, out, err = cli(site_file(media="manual"))
ok("no InsertMedia with media manual: dry run ok", code == 0 and "plan: POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset" in out and "InsertMedia" not in out)

# confirm must match, the ISO must exist, a running server is never reset
F.reset()
code, out, err = cli(site_file(), "-e", "provision_confirm=other")
ok("wrong confirm refused", code == 3 and "provision_confirm must be pve2" in err and F.log == [])
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2")
ok("missing ISO refused", code == 3 and "make provision-iso" in err and not writes())
with open(os.path.join(isodir, "pve2.iso"), "wb") as f:
    f.write(ISO)
F.reset(power="On")
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2")
ok("powered-on target refused, reads only", code == 3 and "Shut it down first" in err and not writes())
F.reset()
code, out, err = cli(site_file(media="manual"), "-e", "provision_confirm=pve2")
ok("manual media needs provision_media_ready", code == 3 and "provision_media_ready" in err and not writes())

# the install run, network dhcp so it does not wait for SSH
F.reset()
code, out, err = cli(site_file(network="dhcp"), "-e", "provision_confirm=pve2")
ok("install run exits 0", code == 0)
seq = [(m, path.rsplit("/", 1)[-1]) for m, path, b in writes()]
ok("install run call order", seq == [("POST", "VirtualMedia.InsertMedia"), ("PATCH", "1"), ("POST", "ComputerSystem.Reset"),
                                     ("POST", "VirtualMedia.EjectMedia"), ("POST", "ComputerSystem.Reset")])
ins = writes()[0][2]
ok("InsertMedia body", ins["Inserted"] is True and ins["WriteProtected"] is True and ins["Image"].startswith("http://127.0.0.1:") and ins["Image"].endswith("/pve2.iso"))
ok("ISO served with byte ranges", F.fetched == (206, f"bytes 10-19/{len(ISO)}", ISO[10:20]))
ok("ISO deleted after the install", not os.path.exists(os.path.join(isodir, "pve2.iso")))
try:
    urllib.request.urlopen(ins["Image"], timeout=2); ok("server stopped after the install", False)
except Exception:
    ok("server stopped after the install", True)
ok("install run prints no password", PW not in out + err)

# the ISO server alone
path = os.path.join(tmp, "x.iso")
with open(path, "wb") as f:
    f.write(ISO)
s2, url = p.serve_iso(path, "127.0.0.1")
def fetch(u, rng=None, method="GET"):
    req = urllib.request.Request(u, method=method, headers={"Range": rng} if rng else {})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, r.headers.get("Content-Range"), r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Range"), b""
ok("whole file", fetch(url)[0] == 200 and fetch(url)[2] == ISO)
ok("suffix range", fetch(url, "bytes=-5") == (206, f"bytes {len(ISO) - 5}-{len(ISO) - 1}/{len(ISO)}", ISO[-5:]))
ok("open range", fetch(url, f"bytes={len(ISO) - 3}-")[2] == ISO[-3:])
ok("range past the end -> 416", fetch(url, f"bytes={len(ISO)}-")[0] == 416)
ok("HEAD has the length", fetch(url, method="HEAD")[0] == 200)
ok("other paths -> 404", fetch(url.rsplit("/", 2)[0] + "/x.iso")[0] == 404)
s2.shutdown()

# IPMI and no-BMC plans
nocreds = os.path.join(tmp, "nocreds.json")
with open(nocreds, "w") as f:
    f.write("{}")
code, out, err = cli(site_file(bmc={"type": "ipmi", "address": "127.0.0.1"}, media="manual"), creds_file=nocreds)
ok("IPMI dry run plan", code == 0 and "plan: ipmitool -I lanplus -H <bmc> -U <user> -E chassis bootdev cdrom options=efiboot" in out
   and "plan: ipmitool -I lanplus -H <bmc> -U <user> -E chassis power on" in out)
code, out, err = cli(site_file(bmc={"type": "none"}, media="manual"))
ok("no BMC: manual steps only", code == 0 and "manual: " in out and "plan: POST" not in out and "ipmitool" not in out)
# media pxe: the dry run plans the netboot service, boot once from the network and power on
F.reset()
code, out, err = cli(site_file(media="pxe"))
plan = [l for l in out.splitlines() if l.startswith(("plan: ", "manual: "))]
want = ["plan: check the netboot payload on the Proxmox host first (make provision-iso NAME=pve2 builds it)",
        "plan: on the Proxmox host, start anvil-netboot-pve2-dhcp: dnsmasq proxyDHCP (no addresses, no DNS) and TFTP on the bridge with the uplink address, PXE answers for 02:00:00:00:00:20 only",
        "plan: on the Proxmox host, start anvil-netboot-pve2-http: the installer kernel and initrd over HTTP on the uplink address, port 18199, at a random path",
        'plan: PATCH /redfish/v1/Systems/1 {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Pxe"}}',
        'plan: POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset {"ResetType": "On"}',
        "plan: wait for the installer kernel and initrd to be served",
        "plan: stop and remove anvil-netboot-pve2-dhcp and anvil-netboot-pve2-http, delete the netboot payload",
        "plan: wait for the installer to power the server off (up to 90 min)",
        'plan: POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset {"ResetType": "On"}',
        "plan: wait for SSH on 192.0.2.12:22"]
ok("pxe dry run with Redfish: plan shape", code == 0 and plan == want)
ok("pxe dry run sends only GETs and needs no ISO", not writes() and "does not exist yet" not in out)

# the install run checks the netboot payload before any request to the BMC
F.reset(power="On")
os.environ.update(PROVISION_BMC_CREDENTIALS_FILE=creds, PROVISION_TEST_REDFISH_URL=f"http://127.0.0.1:{srv.server_address[1]}")
real_remote = p.remote
p.remote = lambda host, script, *a, **k: subprocess.CompletedProcess([], 1, "", "")
e = _raises(lambda: p.run(site_with_m(SITE, media="pxe", bmc={"type": "redfish", "address": "127.0.0.1"}), "pve2",
                          {"provision_confirm": "pve2", "provision_power_off": "true"}, out=lambda line: None))
p.remote = real_remote
ok("pxe install: a missing payload stops the run before any BMC request", e is not None and "make provision-iso" in str(e) and F.log == [])
code, out, err = cli(site_file(media="pxe", bmc={"type": "ipmi", "address": "127.0.0.1"}), creds_file=nocreds)
ok("pxe dry run with IPMI", code == 0 and "plan: ipmitool -I lanplus -H <bmc> -U <user> -E chassis bootdev pxe options=efiboot" in out
   and "plan: ipmitool -I lanplus -H <bmc> -U <user> -E chassis power on" in out)
code, out, err = cli(site_file(media="pxe", bmc={"type": "none"}))
ok("pxe dry run without a BMC", code == 0 and "manual: power the server on and pick network boot (PXE) in its boot menu" in out
   and "plan: wait for the installer kernel and initrd to be served" in out and "PATCH" not in out and "ipmitool" not in out)
code, out, err = cli(site_file(media="pxe", network="dhcp"))
ok("pxe needs the booting MAC", code == 3 and "MAC" in err)
code, out, err = cli(site_file(media="pxe", network="dhcp", mac="02:00:00:00:00:21"))
ok("pxe with network dhcp and mac", code == 0 and "PXE answers for 02:00:00:00:00:21 only" in out)
F.reset()
code, out, err = cli(site_file(media="pxe", network="dhcp", mac=SITE["provision"]["refuse"]["macs"][1]))
ok("pxe with the current server's MAC refused, no request", code == 3 and "current server" in err and F.log == [])
s = copy.deepcopy(SITE); del s["pve"]["uplink_prefix"]
ok("pxe needs the uplink network", "uplink" in str(_raises(lambda: p.pxe_steps(s, "pve2", p.machine(site_with_m(s, media="pxe"), "pve2"), None, None, None, None, False, "plan", lambda l: None))))
ok("netboot scripts: proxy only, target MAC only, no DNS, MAC-named TFTP root",
   all(x in p.NETBOOT_START for x in ("dhcp-range=$net,proxy", "port=0", "dhcp-host=$mac,set:anvil", "dhcp-ignore=tag:!anvil", "tftp-unique-root=mac", "bind-interfaces", "vmbr[0-9]*", "RuntimeMaxSec")))

srv.shutdown()
import shutil; shutil.rmtree(tmp)
sys.exit(1 if fails else 0)
PY2

# --- the Dell controller step and --power-off, against a fake Redfish and WS-Man BMC -------------
python3 - scripts/provision.py site/site.example.yml <<'PY3' || rc=1
import base64, copy, http.server, importlib.util, json, os, re, subprocess, sys, tempfile, threading, urllib.request, yaml
with open(sys.argv[2]) as f:
    SITE = yaml.safe_load(f)["site"]
fails = 0
def ok(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

USER, PW = "bmc-user", "test-only-" + "bmc-secret"
AUTH = "Basic " + base64.b64encode(f"{USER}:{PW}".encode()).decode()
CD = "/redfish/v1/Managers/1/VirtualMedia/CD"
CTRL = "RAID.Integrated.1-1"
BAYS = [f"Disk.Bay.{i}:Enclosure.Internal.0-1:{CTRL}" for i in range(4)]

class Fake:
    def reset(self, power="On", states=("1", "1", "8", "8"), reset_types=("On", "GracefulShutdown", "PushPowerButton"), job_ends="Completed", shuts=True):
        self.power, self.states, self.reset_types, self.job_ends, self.shuts = power, list(states), list(reset_types), job_ends, shuts
        self.log, self.ws, self.fetched, self.gets, self.job_polls = [], [], None, 0, 0

def system():
    F.gets += 1
    if F.power == "On" and F.fetched and F.gets > 3:
        F.power = "Off"
    return {"PowerState": F.power, "SerialNumber": "EXAMPLE2", "SKU": "",
            "Boot": {"BootSourceOverrideTarget@Redfish.AllowableValues": ["Pxe", "Cd", "Hdd"]},
            "Actions": {"#ComputerSystem.Reset": {"target": "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset",
                                                   "ResetType@Redfish.AllowableValues": F.reset_types}},
            "Links": {"ManagedBy": [{"@odata.id": "/redfish/v1/Managers/1"}]}}

GETS = {"/redfish/v1": lambda: {"Systems": {"@odata.id": "/redfish/v1/Systems"}},
        "/redfish/v1/Systems": lambda: {"Members": [{"@odata.id": "/redfish/v1/Systems/1"}]},
        "/redfish/v1/Systems/1": system,
        "/redfish/v1/Managers/1": lambda: {"VirtualMedia": {"@odata.id": "/redfish/v1/Managers/1/VirtualMedia"}},
        "/redfish/v1/Managers/1/VirtualMedia": lambda: {"Members": [{"@odata.id": CD}]},
        CD: lambda: {"MediaTypes": ["CD"], "Inserted": False,
                     "Actions": {"#VirtualMedia.InsertMedia": {"target": CD + "/Actions/VirtualMedia.InsertMedia"},
                                 "#VirtualMedia.EjectMedia": {"target": CD + "/Actions/VirtualMedia.EjectMedia"}}}}

def soap(inner):
    return ('<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:n1="urn:x" '
            'xmlns:wsen="http://schemas.xmlsoap.org/ws/2004/09/enumeration"><s:Body>' + inner + "</s:Body></s:Envelope>")

def wsman(body):
    action = re.search(r"<a:Action[^>]*>([^<]+)<", body).group(1)
    F.ws.append(action.rsplit("/", 1)[-1])
    if action.endswith("/Enumerate"):
        items = "".join(f"<n1:DCIM_PhysicalDiskView><n1:FQDD>{b}</n1:FQDD><n1:Model>ST1000NX0373</n1:Model>"
                        f"<n1:RaidStatus>{s}</n1:RaidStatus></n1:DCIM_PhysicalDiskView>" for b, s in zip(BAYS, F.states))
        return soap(f"<wsen:EnumerateResponse><wsman:Items xmlns:wsman='urn:w'>{items}</wsman:Items><wsman:EndOfSequence xmlns:wsman='urn:w'/></wsen:EnumerateResponse>")
    if action.endswith("/ConvertToNonRAID"):
        F.converted = re.findall(r"<p:PDArray>([^<]+)<", body)
        return soap("<n1:ConvertToNonRAID_OUTPUT><n1:RebootRequired>YES</n1:RebootRequired><n1:ReturnValue>0</n1:ReturnValue></n1:ConvertToNonRAID_OUTPUT>")
    if action.endswith("/CreateTargetedConfigJob"):
        F.job_args = re.findall(r"<p:(Target|RebootJobType|ScheduledStartTime)>([^<]+)<", body)
        return soap("<n1:CreateTargetedConfigJob_OUTPUT><n1:Job><wsa:ReferenceParameters xmlns:wsa='urn:a'><wsman:SelectorSet xmlns:wsman='urn:w'>"
                    "<wsman:Selector Name='InstanceID'>JID_000000000001</wsman:Selector></wsman:SelectorSet></wsa:ReferenceParameters></n1:Job>"
                    "<n1:ReturnValue>4096</n1:ReturnValue></n1:CreateTargetedConfigJob_OUTPUT>")
    if action.endswith("/Get"):
        F.job_polls += 1
        status = "Running" if F.job_polls < 2 else F.job_ends
        if status == "Completed":
            F.states = ["8" if s == "1" else s for s in F.states]
            F.power = "On"
        return soap(f"<n1:DCIM_LifecycleJob><n1:InstanceID>JID_000000000001</n1:InstanceID><n1:JobStatus>{status}</n1:JobStatus>"
                    "<n1:Message>test</n1:Message></n1:DCIM_LifecycleJob>")
    return soap("<s:Fault><s:Reason>unknown</s:Reason></s:Fault>")

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def reply(self, code, data=b"", ctype="application/json"):
        self.send_response(code); self.send_header("Content-Type", ctype); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def handle_any(self, method):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n)
        if self.headers.get("Authorization") != AUTH:
            return self.reply(401)
        if self.path == "/wsman":
            return self.reply(200, wsman(raw.decode()).encode(), "application/soap+xml")
        body = json.loads(raw or b"null")
        F.log.append((method, self.path, body))
        if method == "GET":
            return self.reply(200, json.dumps(GETS[self.path]()).encode()) if self.path in GETS else self.reply(404)
        if self.path.endswith("VirtualMedia.InsertMedia"):
            with urllib.request.urlopen(urllib.request.Request(body["Image"], headers={"Range": "bytes=0-9"})) as r:
                F.fetched = r.status
        elif self.path.endswith("ComputerSystem.Reset"):
            if body["ResetType"] == "On":
                F.power = "On"; F.gets = 0
            elif body["ResetType"] in ("GracefulShutdown", "PushPowerButton") and F.shuts:
                F.power = "Off"
        self.reply(204)
    def do_GET(self): self.handle_any("GET")
    def do_POST(self): self.handle_any("POST")
    def do_PATCH(self): self.handle_any("PATCH")

F = Fake(); F.reset()
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{srv.server_address[1]}"
tmp = tempfile.mkdtemp()
creds = os.path.join(tmp, "creds.json")
with open(creds, "w") as f:
    json.dump({"username": USER, "password": PW}, f)
isodir = os.path.join(tmp, "iso"); os.mkdir(isodir)

def site_file(**machine):
    s = copy.deepcopy(SITE)
    s["provision"]["machines"]["pve2"].update({"bmc": {"type": "redfish", "address": "127.0.0.1"}, "network": "dhcp",
                                               "mac": "02:00:00:00:00:20", "controller": {"vendor": "dell", "mode": "nonraid"}}, **machine)
    path = os.path.join(tmp, "site.json")
    with open(path, "w") as f:
        json.dump({"site": s}, f)
    return path

def cli(site, *extra):
    env = dict(os.environ, PROVISION_SITE_FILE=site, PROVISION_BMC_CREDENTIALS_FILE=creds, PROVISION_TEST_REDFISH_URL=base,
               PROVISION_TEST_WSMAN_URL=base + "/wsman", PROVISION_ISO_DIR=isodir, PROVISION_TEST_POLL_SCALE="0.001")
    r = subprocess.run([sys.executable, sys.argv[1], "run", "--name", "pve2", *extra], env=env, capture_output=True, text=True, timeout=120)
    return r.returncode, r.stdout, r.stderr

def writes():
    return [(m, p.rsplit("/", 1)[-1], b) for m, p, b in F.log if m != "GET"]

def iso():
    with open(os.path.join(isodir, "pve2.iso"), "wb") as f:
        f.write(b"x" * 4096)

code, out, err = cli(site_file(controller={"vendor": "hp"}))
ok("controller: only dell nonraid", code == 3 and "controller is" in err)
code, out, err = cli(site_file(bmc={"type": "none"}, media="manual"))
ok("controller needs a BMC", code == 3 and "controller needs a BMC" in err)

F.reset()
code, out, err = cli(site_file())
ok("dry run without --power-off notes the running server", code == 0 and "or add --power-off" in out)
F.reset()
code, out, err = cli(site_file(), "-e", "provision_power_off=true")
ok("dry run exits 0", code == 0)
ok("dry run plans the conversion of the Ready disks", "plan: WS-Man DCIM_RAIDService.ConvertToNonRAID, 2 Ready disks on " + CTRL in out)
ok("dry run plans a graceful shutdown", 'plan: POST /redfish/v1/Systems/1/Actions/ComputerSystem.Reset {"ResetType": "GracefulShutdown"}' in out
   and "never forced" in out)
ok("dry run: WS-Man reads only, no Redfish writes", F.ws == ["Enumerate"] and not writes())
ok("dry run prints no password", PW not in out + err)

F.reset()
iso()
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2")
ok("the controller step needs --power-off", code == 3 and "--power-off" in err and F.ws == [] and not writes())

F.reset(states=("1", "2", "8", "8"))
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2", "-e", "provision_power_off=true")
ok("a disk in a RAID volume is refused, nothing written", code == 3 and "never deletes one" in err and F.ws == ["Enumerate"] and not writes())

F.reset()
iso()
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2", "-e", "provision_power_off=true")
ok("install with the controller step and --power-off exits 0", code == 0)
ok("only the Ready disks are converted", F.converted == BAYS[:2])
ok("one job, graceful reboot, now", dict(F.job_args) == {"Target": CTRL, "RebootJobType": "3", "ScheduledStartTime": "TIME_NOW"})
ok("WS-Man order", F.ws[:3] == ["Enumerate", "ConvertToNonRAID", "CreateTargetedConfigJob"] and F.ws[-1] == "Enumerate")
seq = [(m, p, (b or {}).get("ResetType")) for m, p, b in writes()]
ok("shut down gracefully, then the install", seq[0] == ("POST", "ComputerSystem.Reset", "GracefulShutdown")
   and ("POST", "VirtualMedia.InsertMedia", None) in seq and "ForceOff" not in json.dumps(seq))
ok("no password printed", PW not in out + err)

F.reset(states=("8", "8", "8", "8"), reset_types=("On", "PushPowerButton"))
iso()
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2", "-e", "provision_power_off=true")
ok("all Non-RAID: no job; PushPowerButton when no GracefulShutdown", code == 0 and F.ws == ["Enumerate"]
   and writes()[0][2] == {"ResetType": "PushPowerButton"})

F.reset(states=("8", "8", "8", "8"), shuts=False)
iso()
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2", "-e", "provision_power_off=true")
ok("a server that does not shut down is refused, never forced", code == 3 and "never forces it off" in err
   and not any(b and b.get("ResetType") == "ForceOff" for _, _, b in writes()))

F.reset(job_ends="Failed")
iso()
code, out, err = cli(site_file(), "-e", "provision_confirm=pve2", "-e", "provision_power_off=true")
ok("a failed job stops the run before the install", code == 3 and "Failed" in err and not writes())

srv.shutdown()
import shutil; shutil.rmtree(tmp)
sys.exit(1 if fails else 0)
PY3

# The CLI exits 3 on a refusal and never echoes the password.
out=$(printf 'test-only-cli-value\n' | PROVISION_SITE_FILE=site/site.example.yml python3 scripts/provision.py answer --name pve2 --ssh-key /dev/null 2>&1)
code=$?
if [ "$code" = 3 ] && ! grep -q test-only-cli-value <<<"$out"; then echo "ok   CLI refuses an empty key file, no echo"; else echo "FAIL CLI refusal ($code)"; rc=1; fi

exit "$rc"
