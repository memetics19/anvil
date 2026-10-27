#!/usr/bin/env python3
"""Bare-metal provisioning of a Proxmox VE server with the automated installer
(docs/provisioning.md). Brand agnostic: the answer file is plain Proxmox, the BMC is
driven only through standard DMTF Redfish or plain IPMI.

  provision.py answer --name <box> [--ssh-key <file>]   root password on stdin
      prints the installer answer file (TOML) for site.provision.machines.<box>
  provision.py check --name <box>
      checks the machine entry and the guard against the current server, no network
  provision.py run --name <box> [-e provision_confirm=<box>] [-e provision_media_ready=true]
                   [-e provision_power_off=true]
      a dry run by default: the guard, read-only BMC reads, then the plan, one line per
      Redfish or IPMI call (no secrets). With provision_confirm equal to the name it runs:
      serve the ISO over HTTP, insert it (media redfish), boot once from CD, power on, wait
      for the installer to power off, eject, power on, wait for SSH, delete the ISO.
      media pxe: a temporary proxyDHCP, TFTP and HTTP netboot service on the Proxmox host
      answers only the target's MAC, boots it once from the network into the installer,
      and is stopped and removed at the end, also when the run fails.
      controller: {vendor: dell, mode: nonraid} first turns Ready disks into Non-RAID
      disks (scripts/provision_dell.py, the one vendor-specific part). provision_power_off
      shuts a running target down gracefully (never forced) before the install.
  provision.py serve --bind <addr> --port <n> --token <t> --file <name>=<path> ...
      the netboot HTTP server (run on the Proxmox host by media pxe)
  provision.py get --name <box> --key <key>
      prints one field of the checked machine entry, for scripts

The site dict comes from $PROVISION_SITE_FILE (JSON or YAML, with or without a top-level
`site` key) or else from $TF_VAR_site_json (scripts/env.sh). Nothing secret is printed:
the answer file holds only the password hash, and the plaintext stays in Vault.
"""
import argparse
import base64
import http.server
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request



class Refused(Exception):
    """A request this tool will not carry out. The message says why."""


# --- site ------------------------------------------------------------------------------------

def load_site():
    path = os.environ.get("PROVISION_SITE_FILE")
    if path:
        with open(path, encoding="utf-8") as f:
            text = f.read()
        try:
            doc = json.loads(text)
        except ValueError:
            import yaml  # only for YAML files (tests read site/site.example.yml)
            doc = yaml.safe_load(text)
    else:
        raw = os.environ.get("TF_VAR_site_json")
        if not raw:
            raise Refused("no site data: source scripts/env.sh first (TF_VAR_site_json)")
        doc = json.loads(raw)
    if isinstance(doc, dict) and isinstance(doc.get("site"), dict):
        doc = doc["site"]
    if not isinstance(doc, dict):
        raise Refused("the site data is not a dict")
    return doc


def norm_mac(mac):
    m = str(mac).strip().lower().replace("-", ":")
    if not re.fullmatch(r"([0-9a-f]{2}:){5}[0-9a-f]{2}", m):
        raise Refused(f"not a MAC address: {mac!r}")
    return m


def norm_serial(s):
    return str(s).strip().upper()


def machine(site, name):
    """The machine entry, checked and with defaults filled in."""
    machines = (site.get("provision") or {}).get("machines") or {}
    if name not in machines:
        raise Refused(f"no site.provision.machines.{name}")
    m = dict(machines[name] or {})
    if not re.fullmatch(r"[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?", name):
        raise Refused(f"{name}: a machine name is a lower-case host name")
    m.setdefault("hostname", name)
    m.setdefault("keyboard", "en-us")
    m.setdefault("country", "us")
    m.setdefault("timezone", "UTC")
    m.setdefault("media", "manual")
    m.setdefault("boot_mode", "uefi")
    bmc = dict(m.get("bmc") or {"type": "none"})
    if bmc.get("type") not in ("redfish", "ipmi", "none"):
        raise Refused(f"{name}: bmc.type is redfish, ipmi or none")
    if bmc["type"] != "none" and not bmc.get("address"):
        raise Refused(f"{name}: bmc.address is required for bmc.type {bmc['type']}")
    m["bmc"] = bmc
    if m["media"] not in ("redfish", "manual", "pxe"):
        raise Refused(f"{name}: media is redfish, manual or pxe")
    if m["media"] == "redfish" and bmc["type"] != "redfish":
        raise Refused(f"{name}: media redfish needs bmc.type redfish")
    if m["boot_mode"] not in ("uefi", "bios"):
        raise Refused(f"{name}: boot_mode is uefi or bios")
    net = m.get("network")
    if net == "dhcp":
        pass
    elif isinstance(net, dict):
        for k in ("cidr", "gateway", "dns", "mac"):
            if not net.get(k):
                raise Refused(f"{name}: network.{k} is required for a static network (or set network: dhcp)")
        try:
            iface = ipaddress.ip_interface(str(net["cidr"]))
            gw = ipaddress.ip_address(str(net["gateway"]))
            ipaddress.ip_address(str(net["dns"]))
        except ValueError as e:
            raise Refused(f"{name}: network: {e}") from None
        if iface.network.prefixlen == iface.network.max_prefixlen or gw not in iface.network:
            raise Refused(f"{name}: network.gateway is not inside network.cidr")
        net = dict(net, mac=norm_mac(net["mac"]))
    else:
        raise Refused(f"{name}: network is dhcp or a dict with cidr, gateway, dns and mac")
    m["network"] = net
    ctl = m.get("controller")
    if ctl is not None:
        if ctl != {"vendor": "dell", "mode": "nonraid"}:
            raise Refused(f"{name}: controller is {{vendor: dell, mode: nonraid}} or absent")
        if bmc["type"] == "none":
            raise Refused(f"{name}: controller needs a BMC (bmc.type redfish or ipmi)")
    m["disk_setup"] = disk_setup(name, m.get("disks"))
    # The NIC that boots from the network: network.mac, or mac for a DHCP network.
    boot_mac = m.get("mac") or (net.get("mac") if isinstance(net, dict) else None)
    m["boot_mac"] = norm_mac(boot_mac) if boot_mac else None
    if m["media"] == "pxe" and not m["boot_mac"]:
        raise Refused(f"{name}: media pxe needs the booting NIC's MAC (network.mac, or mac with network: dhcp)")
    return m


WILDCARDS = re.compile(r"[*?\[\]!]")


def disk_setup(name, disks):
    """One disk: ext4 on LVM, on the disk a udev filter (or a kernel name) picks. Two disk
    names: a ZFS mirror. Never a filter for a mirror, which takes every disk it matches."""
    if not isinstance(disks, list) or len(disks) not in (1, 2):
        raise Refused(f"{name}: disks must list one disk (ext4) or two disk names (ZFS mirror)")
    names = [d for d in disks if isinstance(d, str)]
    for d in names:
        if not re.fullmatch(r"[a-z][a-z0-9]*", d):
            raise Refused(f"{name}: {d!r} is not a kernel disk name such as sda or nvme0n1")
    if len(disks) == 2:
        if len(names) != 2:
            raise Refused(f"{name}: a ZFS mirror needs two disk names; a filter would take every disk it matches")
        if names[0] == names[1]:
            raise Refused(f"{name}: the two mirror disks are the same")
        return {"filesystem": "zfs", "zfs.raid": "raid1", "disk_list": names}
    d = disks[0]
    if isinstance(d, str):
        return {"filesystem": "ext4", "disk_list": [d]}
    if not isinstance(d, dict) or not d:
        raise Refused(f"{name}: a disk is a kernel name or a udev filter such as {{ID_SERIAL: ...}}")
    flt = {}
    for k, v in d.items():
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", str(k)):
            raise Refused(f"{name}: {k!r} is not a udev property name")
        v = str(v)
        if not WILDCARDS.sub("", v).strip():
            raise Refused(f"{name}: the disk filter {k}={v!r} matches any disk")
        flt[str(k)] = v
    return {"filesystem": "ext4", "filter": flt, "filter_match": "all"}


# --- the guard against the current server -----------------------------------------------------

def refuse_lists(site):
    """The current server's identifiers. Its BMC and host addresses are added from site.pve."""
    r = (site.get("provision") or {}).get("refuse") or {}
    pve = site.get("pve") or {}
    addrs = {str(a).strip().lower() for a in r.get("bmc_addresses") or []}
    addrs |= {str(pve[k]).strip().lower() for k in ("idrac_ip", "ip", "uplink_ip", "gateway_alias_ip") if pve.get(k)}
    macs = {norm_mac(x) for x in r.get("macs") or []}
    serials = {norm_serial(x) for x in r.get("serials") or [] if str(x).strip()}
    return addrs, macs, serials


def static_guard(site, name, m):
    addrs, macs, serials = refuse_lists(site)
    if not macs or not serials:
        raise Refused("site.provision.refuse needs the current server's NIC MACs and serials; every target is refused until it has them")
    bmc = m["bmc"]
    if bmc["type"] != "none" and str(bmc["address"]).strip().lower() in addrs:
        raise Refused(f"{name}: bmc.address is the current server's (refused)")
    if m["boot_mac"] and m["boot_mac"] in macs:
        raise Refused(f"{name}: mac is one of the current server's NICs (refused)")
    if isinstance(m["network"], dict):
        if m["network"]["mac"] in macs:
            raise Refused(f"{name}: network.mac is one of the current server's NICs (refused)")
        ip = str(ipaddress.ip_interface(str(m["network"]["cidr"])).ip)
        used = set(addrs)
        for h in (site.get("hosts") or {}).values():
            for k in ("ip", "lab_ip", "home_ip"):
                if isinstance(h, dict) and h.get(k):
                    used.add(str(h[k]))
        if ip in used:
            raise Refused(f"{name}: network.cidr's address is already in use by the lab (refused)")
    if m.get("serial") and norm_serial(m["serial"]) in serials:
        raise Refused(f"{name}: serial is the current server's (refused)")


def live_guard(site, name, m, read_serials):
    """Serials the target's BMC reported (Redfish SerialNumber and SKU, or IPMI FRU)."""
    _, _, serials = refuse_lists(site)
    seen = {norm_serial(s) for s in read_serials if s and str(s).strip()}
    if seen & serials:
        raise Refused(f"{name}: the BMC reports a serial of the current server (refused)")
    if m.get("serial") and norm_serial(m["serial"]) not in seen:
        raise Refused(f"{name}: the BMC does not report the expected serial; is bmc.address the right box?")


# --- the answer file --------------------------------------------------------------------------

def openssl_bin():
    for c in (os.environ.get("PROVISION_OPENSSL"), "openssl", "/opt/homebrew/bin/openssl", "/usr/local/opt/openssl@3/bin/openssl"):
        p = c and shutil.which(c)
        if not p:
            continue
        r = subprocess.run([p, "passwd", "-6", "-stdin"], input="probe\n", capture_output=True, text=True, check=False)
        if r.returncode == 0 and r.stdout.startswith("$6$"):
            return p
    raise Refused("no openssl with passwd -6 (OpenSSL 1.1.1 or newer); brew install openssl@3")


def hash_password(plain):
    """SHA-512 crypt of the password. The plaintext goes to openssl on stdin, never argv."""
    if not plain or "\n" in plain:
        raise Refused("the root password is empty or has a line break")
    r = subprocess.run([openssl_bin(), "passwd", "-6", "-stdin"], input=plain + "\n", capture_output=True, text=True, check=False)
    h = r.stdout.strip()
    if r.returncode != 0 or not h.startswith("$6$"):
        raise Refused("openssl passwd failed")
    return h


def q(v):
    """A TOML basic string (JSON's escapes are valid TOML)."""
    return json.dumps(str(v), ensure_ascii=False)


def answer(site, name, password_hash, ssh_keys):
    m = machine(site, name)
    if not password_hash.startswith("$6$"):
        raise Refused("the root password must be a SHA-512 crypt hash")
    if not ssh_keys:
        raise Refused("no operator SSH public key")
    domain = site.get("domain")
    if not domain:
        raise Refused("site.domain is missing")
    lines = [
        "# Proxmox VE automated installer answer file, rendered by scripts/provision.py.",
        "# It holds a password hash: keep it out of the repo and delete it after use.",
        "[global]",
        f"keyboard = {q(m['keyboard'])}",
        f"country = {q(m['country'])}",
        f"fqdn = {q(m['hostname'] + '.' + domain)}",
        f"mailto = {q(site.get('email') or 'root@' + domain)}",
        f"timezone = {q(m['timezone'])}",
        f"root_password_hashed = {q(password_hash)}",
        "root_ssh_keys = [" + ", ".join(q(k) for k in ssh_keys) + "]",
        # Power off at the end, so a still attached ISO cannot start a second install.
        'reboot_mode = "power-off"',
        "",
        "[network]",
    ]
    net = m["network"]
    if net == "dhcp":
        lines.append('source = "from-dhcp"')
    else:
        lines += [
            'source = "from-answer"',
            f"cidr = {q(net['cidr'])}",
            f"gateway = {q(net['gateway'])}",
            f"dns = {q(net['dns'])}",
            f"filter.ID_NET_NAME_MAC = {q('*' + net['mac'].replace(':', ''))}",
        ]
    ds = m["disk_setup"]
    lines += ["", "[disk-setup]", f"filesystem = {q(ds['filesystem'])}"]
    if "zfs.raid" in ds:
        lines.append(f"zfs.raid = {q(ds['zfs.raid'])}")
    if "disk_list" in ds:
        lines.append("disk_list = [" + ", ".join(q(d) for d in ds["disk_list"]) + "]")
    else:
        for k, v in ds["filter"].items():
            lines.append(f"filter.{k} = {q(v)}")
        lines.append(f"filter_match = {q(ds['filter_match'])}")
    return "\n".join(lines) + "\n"


def read_ssh_keys(path):
    with open(os.path.expanduser(path), encoding="utf-8") as f:
        keys = [ln.strip() for ln in f if ln.strip() and not ln.startswith("#")]
    for k in keys:
        if not re.match(r"(ssh-|ecdsa-|sk-)", k) or "PRIVATE KEY" in k:
            raise Refused(f"{path} is not an SSH public key file")
    return keys


# --- BMC access: standard DMTF Redfish or plain IPMI only -------------------------------------

def bmc_ssl_context():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE  # BMCs have self-signed certificates
    try:
        ctx.set_ciphers("DEFAULT:@SECLEVEL=0")  # older BMC firmware
    except ssl.SSLError:
        pass
    ctx.options |= getattr(ssl, "OP_LEGACY_SERVER_CONNECT", 0)
    return ctx


class Redfish:
    """Basic auth on every request (no session is created). get() is read-only."""

    def __init__(self, address, user, password, timeout=30):
        self.base = os.environ.get("PROVISION_TEST_REDFISH_URL") or f"https://{address}"  # the URL override is for tests only
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.timeout = timeout
        self.ctx = bmc_ssl_context()

    def request(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Authorization", self.auth)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                text = r.read().decode() or "{}"
        except urllib.error.HTTPError as e:
            raise Refused(f"{method} {path}: HTTP {e.code}") from None
        except (urllib.error.URLError, OSError) as e:
            raise Refused(f"{method} {path}: {getattr(e, 'reason', e)}") from None
        try:
            return json.loads(text)
        except ValueError:
            return {}

    def get(self, path):
        return self.request("GET", path)


def odata(d, key):
    v = d.get(key)
    return v.get("@odata.id") if isinstance(v, dict) else None


def redfish_discover(rf, out):
    """Read-only: the one system, its power state and serials, and the virtual CD."""
    out("read: GET /redfish/v1")
    root = rf.get("/redfish/v1")
    col = odata(root, "Systems") or "/redfish/v1/Systems"
    out(f"read: GET {col}")
    members = rf.get(col).get("Members") or []
    if len(members) != 1:
        raise Refused(f"the BMC lists {len(members)} systems; this tool handles exactly one")
    sp = members[0]["@odata.id"]
    out(f"read: GET {sp}")
    sysd = rf.get(sp)
    info = {"system": sp, "power": sysd.get("PowerState"), "serials": [sysd.get("SerialNumber"), sysd.get("SKU")]}
    reset = (sysd.get("Actions") or {}).get("#ComputerSystem.Reset") or {}
    info["reset"] = reset.get("target")
    info["reset_types"] = reset.get("ResetType@Redfish.AllowableValues")
    info["boot_targets"] = (sysd.get("Boot") or {}).get("BootSourceOverrideTarget@Redfish.AllowableValues")
    # Virtual media: under the system (newer Redfish) or under its manager.
    places = [odata(sysd, "VirtualMedia")]
    mgr = ((sysd.get("Links") or {}).get("ManagedBy") or [{}])[0].get("@odata.id")
    if not mgr:
        mcol = odata(root, "Managers")
        mm = rf.get(mcol).get("Members") if mcol else []
        mgr = mm[0]["@odata.id"] if mm else None
    if mgr:
        out(f"read: GET {mgr}")
        places.append(odata(rf.get(mgr), "VirtualMedia"))
    info["cd"] = None
    for vcol in [x for x in places if x]:
        out(f"read: GET {vcol}")
        for mem in rf.get(vcol).get("Members") or []:
            out(f"read: GET {mem['@odata.id']}")
            vm = rf.get(mem["@odata.id"])
            if {"CD", "DVD"} & set(vm.get("MediaTypes") or []):
                acts = vm.get("Actions") or {}
                ins = acts.get("#VirtualMedia.InsertMedia") or {}
                info["cd"] = {
                    "path": mem["@odata.id"],
                    "insert": ins.get("target"),
                    "protocols": ins.get("TransferProtocolType@Redfish.AllowableValues"),
                    "eject": (acts.get("#VirtualMedia.EjectMedia") or {}).get("target"),
                    "inserted": vm.get("Inserted"),
                }
                break
        if info["cd"]:
            break
    return info


class Ipmi:
    """ipmitool over lanplus. The password reaches it only through IPMI_PASSWORD (-E)."""

    def __init__(self, address, user, password):
        self.address = address
        self.user = user
        self.secret = password

    def shown(self, args):
        return "ipmitool -I lanplus -H <bmc> -U <user> -E " + " ".join(args)

    def call(self, args):
        if not shutil.which("ipmitool"):
            raise Refused("ipmitool is not installed (brew install ipmitool)")
        env = dict(os.environ, IPMI_PASSWORD=self.secret)
        r = subprocess.run(["ipmitool", "-I", "lanplus", "-H", self.address, "-U", self.user, "-E", *args],
                           env=env, capture_output=True, text=True, timeout=60, check=False)
        if r.returncode != 0:
            raise Refused(f"{self.shown(args)}: exit {r.returncode}")
        return r.stdout

    def power(self):
        out = self.call(["chassis", "power", "status"]).lower()
        return "On" if " on" in out else "Off" if " off" in out else "Unknown"

    def serials(self):
        found = []
        for line in self.call(["fru", "print", "0"]).splitlines():
            k, _, v = line.partition(":")
            if k.strip() in ("Product Serial", "Chassis Serial", "Board Serial"):
                found.append(v.strip())
        return found


# --- serving the ISO --------------------------------------------------------------------------

class IsoHandler(http.server.BaseHTTPRequestHandler):
    """Serves fixed files at fixed paths, with single byte ranges (BMCs read the ISO in
    ranges). Prints "served <name>" when a whole file was sent."""
    server_version = "anvil-provision"

    def log_message(self, *args):
        pass

    def do_HEAD(self):
        self.serve(False)

    def do_GET(self):
        self.serve(True)

    def serve(self, body):
        srv = self.server
        if self.path not in srv.files:
            self.send_error(404)
            return
        label, path = srv.files[self.path]
        size = os.path.getsize(path)
        start, end, status = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            m = re.fullmatch(r"bytes=(\d*)-(\d*)", rng.strip())
            if m and m.group(1):
                start = int(m.group(1))
                end = min(int(m.group(2)), size - 1) if m.group(2) else size - 1
            elif m and m.group(2):
                start = max(0, size - int(m.group(2)))
            if not m or not (m.group(1) or m.group(2)) or start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            status = 206
        self.send_response(status)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if not body:
            return
        left = end - start + 1
        try:
            with open(path, "rb") as f:
                f.seek(start)
                while left > 0:
                    chunk = f.read(min(left, 1 << 20))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
            srv.requests += 1
            if srv.announce and start == 0 and end == size - 1 and left == 0:
                print(f"served {label}", flush=True)
        except (BrokenPipeError, ConnectionResetError):
            pass


def serve_files(files, bind, port=0, token=None):
    """Serve {name: path} at /<token>/<name> on bind:port in a thread. Returns the server."""
    srv = http.server.ThreadingHTTPServer((bind, port), IsoHandler)
    srv.daemon_threads = True
    srv.token = token or secrets.token_urlsafe(16)
    srv.files = {f"/{srv.token}/{n}": (n, pth) for n, pth in files.items()}
    srv.requests = 0
    srv.announce = False
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


def serve_iso(path, bind, port=0):
    """Start serving `path` on bind:port at a random path. Returns the server and its URL."""
    name = os.path.basename(path)
    srv = serve_files({name: path}, bind, port)
    return srv, f"http://{bind}:{srv.server_address[1]}/{srv.token}/{name}"


def local_address_towards(address):
    """The Mac's address on the route to the BMC (no packet is sent)."""
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect((address, 9))
        return s.getsockname()[0]


# --- the run ----------------------------------------------------------------------------------

def bmc_credentials(name):
    path = os.environ.get("PROVISION_BMC_CREDENTIALS_FILE")  # tests only
    if path:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    else:
        r = subprocess.run(["vault", "kv", "get", "-format=json", "-mount=kv", f"homelab/{name}/bmc"],
                           capture_output=True, text=True, check=False)
        if r.returncode != 0:
            return None
        d = json.loads(r.stdout).get("data", {}).get("data", {})
    if not d.get("username") or not d.get("password"):
        return None
    return d["username"], d["password"]


def wait_for(what, check, timeout, every, out):
    out(f"wait: {what} (up to {timeout // 60} min)")
    scale = float(os.environ.get("PROVISION_TEST_POLL_SCALE", "1"))  # tests only
    every *= scale
    end = time.monotonic() + timeout * scale
    while time.monotonic() < end:
        if check():
            return
        time.sleep(every)
    raise Refused(f"timed out waiting: {what}")


def ssh_open(ip):
    try:
        with socket.create_connection((ip, 22), timeout=5):
            return True
    except OSError:
        return False


def handoff(name, m, out):
    out("next: the install is done. Hand it to the repo (docs/provisioning.md, After the install):")
    out("next:   add the host to the inventory, then make bootstrap-ssh and make host for it, or anvil up")
    if m["network"] == "dhcp":
        out("next:   it took a DHCP address; find it in the router's lease table")


def run(site, name, opts, out=print):
    unknown = set(opts) - {"provision_confirm", "provision_media_ready", "provision_power_off"}
    if unknown:
        raise Refused("unknown option: " + ", ".join(sorted(unknown)))
    m = machine(site, name)
    static_guard(site, name, m)  # before any network access or credential read
    apply = "provision_confirm" in opts
    if apply and opts["provision_confirm"] != name:
        raise Refused(f"provision_confirm must be {name}")
    media_ready = str(opts.get("provision_media_ready", "")).lower() in ("true", "yes", "1")
    power_off = str(opts.get("provision_power_off", "")).lower() in ("true", "yes", "1")
    if apply and m.get("controller") and not power_off:
        raise Refused("the controller step reboots the server, so it is running afterwards. Add --power-off "
                      "(-e provision_power_off=true) to shut it down before the install")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    iso = os.path.join(os.environ.get("PROVISION_ISO_DIR") or os.path.join(root, "build", "provision"), f"{name}.iso")  # the override is for tests only
    rel = os.path.relpath(iso, root)
    bmc = m["bmc"]
    word = "do" if apply else "plan"
    out(f"provision {name}: " + ("APPLY" if apply else f"dry run, nothing changes. Apply with -e provision_confirm={name}"))
    out("guard: ok (BMC address, NIC MAC and serial are not the current server's)")
    pxe = m["media"] == "pxe"
    if apply and not pxe and not os.path.exists(iso):
        raise Refused(f"{rel} is missing: make provision-iso NAME={name}")
    if not pxe and not os.path.exists(iso):
        out(f"note: {rel} does not exist yet (make provision-iso NAME={name})")
    # The netboot payload lives on the Proxmox host. Checked before any request to the BMC,
    # so a missing one stops the run before the server is touched.
    if pxe and apply:
        host = netboot_host(site)
        r = remote(host, NETBOOT_PAYLOAD_CHECK, name, check=False)
        if r.returncode != 0:
            raise Refused(f"no netboot payload for {name} on {host}: make provision-iso NAME={name}")
        out(f"read: the netboot payload for {name} is on the Proxmox host")
    elif pxe:
        out(f"plan: check the netboot payload on the Proxmox host first (make provision-iso NAME={name} builds it)")
    static_ip = None if m["network"] == "dhcp" else str(ipaddress.ip_interface(m["network"]["cidr"]).ip)

    if bmc["type"] == "none" and pxe:
        return pxe_steps(site, name, m, None, None, None, static_ip, apply, word, out)
    if bmc["type"] == "none":
        out("manual: no BMC. By hand:")
        manual_media_steps(name, rel, out)
        out("manual: power the server on and pick the USB stick or virtual CD in its boot menu")
        out("manual: the installer powers the server off when it is done. Remove the media, then power it on")
        if apply and static_ip:
            wait_for(f"SSH on {static_ip}:22", lambda: ssh_open(static_ip), 120 * 60, 15, out)
            handoff(name, m, out)
        return 0

    creds = bmc_credentials(name)
    if not creds and apply:
        raise Refused(f"no username and password at kv/homelab/{name}/bmc")
    info = None
    if creds and bmc["type"] == "redfish":
        rf = Redfish(bmc["address"], *creds)
        try:
            info = redfish_discover(rf, out)
        except Refused as e:
            if apply:
                raise
            out(f"read: skipped, the BMC did not answer ({e})")
    elif creds:
        ip = Ipmi(bmc["address"], *creds)
        try:
            out("read: " + ip.shown(["fru", "print", "0"]))
            info = {"serials": ip.serials()}
            out("read: " + ip.shown(["chassis", "power", "status"]))
            info["power"] = ip.power()
        except Refused as e:
            if apply:
                raise
            out(f"read: skipped, the BMC did not answer ({e})")
    else:
        out(f"read: skipped, no credentials at kv/homelab/{name}/bmc")

    if info:
        live_guard(site, name, m, info["serials"])
        out(f"read: serial check ok, power {info['power']}")

    def power_now():
        return rf.get(info["system"]).get("PowerState") if bmc["type"] == "redfish" else ip.power()

    # After the serial check: the BMC is the target's, never the current server's.
    if m.get("controller"):
        # Imported here, not at the top: the netboot HTTP server runs this file alone on the
        # Proxmox host (provision.py serve), where provision_dell.py is not copied.
        sys.dont_write_bytecode = True  # no __pycache__ in scripts/ (tests/test_media_untouched.sh)
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import provision_dell
        if info:
            ws = provision_dell.WSMan(bmc["address"], *creds, bmc_ssl_context())
            try:
                if provision_dell.nonraid(ws, apply, word, out, wait_for):
                    info["power"] = power_now()
            except provision_dell.DellError as e:
                if apply:
                    raise Refused(str(e)) from None
                out(f"note: {e}")
        else:
            out("plan: Dell controller: turn Ready disks into Non-RAID disks (no reads: the BMC did not answer)")

    if info and info["power"] != "Off":
        if power_off:
            shut_down(bmc["type"], rf if bmc["type"] == "redfish" else None, ip if bmc["type"] == "ipmi" else None,
                      info, power_now, apply, word, out)
        else:
            msg = (f"{name} is powered {info['power']}. Shut it down first, or add --power-off "
                   "(-e provision_power_off=true): this tool never resets a running server")
            if apply:
                raise Refused(msg)
            out("note: " + msg)

    want_boot = "Pxe" if pxe else "Usb" if m.get("boot_device") == "usb" else "Cd"
    if bmc["type"] == "redfish":
        sysp = info["system"] if info else "<system>"
        reset = info["reset"] if info and info["reset"] else f"{sysp}/Actions/ComputerSystem.Reset"
        if info:
            if info["reset_types"] and "On" not in info["reset_types"]:
                raise Refused("the BMC does not offer ComputerSystem.Reset On")
            if info["boot_targets"] and want_boot not in info["boot_targets"]:
                raise Refused(f"the BMC does not offer BootSourceOverrideTarget {want_boot}")
        cd = info["cd"] if info else None
        if pxe:
            ops = RedfishPower(rf if info else None, sysp, reset, apply, word, out)
            return pxe_steps(site, name, m, ops, ops.boot_once_pxe, ops.power_on, static_ip, apply, word, out)
        if m["media"] == "redfish":
            if info and not (cd and cd["insert"] and cd["eject"]):
                raise Refused("this BMC has no standard VirtualMedia.InsertMedia and EjectMedia for a CD. Set media: manual")
            if cd and cd["protocols"] and "HTTP" not in cd["protocols"]:
                raise Refused("this BMC's InsertMedia does not take HTTP. Set media: manual")
            if cd and cd["inserted"]:
                raise Refused("the virtual CD already holds media. Eject it first")
        return redfish_steps(name, m, rf if info else None, info, cd, sysp, reset, want_boot, iso, rel, static_ip, apply, media_ready, word, out)
    if pxe:
        ops = IpmiPower(m, ip if info else None, apply, word, out)
        return pxe_steps(site, name, m, ops, ops.boot_once_pxe, ops.power_on, static_ip, apply, word, out)
    return ipmi_steps(name, m, ip if info else None, iso, rel, static_ip, apply, media_ready, word, out)


def shut_down(kind, rf, ip, info, power_now, apply, word, out):
    """A graceful shutdown of the target, then wait until it is off. Never a forced one: a
    server that does not shut down is refused, for the operator to look at."""
    if kind == "redfish":
        types = info.get("reset_types") or []
        how = next((t for t in ("GracefulShutdown", "PushPowerButton") if t in types), None)
        if not how:
            raise Refused("the BMC offers neither GracefulShutdown nor PushPowerButton. Shut the server down by hand")
        out(f"{word}: POST {info['reset']} " + json.dumps({"ResetType": how}))
        if apply:
            rf.request("POST", info["reset"], {"ResetType": how})
    else:
        out(f"{word}: " + Ipmi("", "", "").shown(["chassis", "power", "soft"]))
        if apply:
            ip.call(["chassis", "power", "soft"])
    if apply:
        try:
            wait_for("the server to shut down", lambda: power_now() == "Off", 15 * 60, 15, out)
        except Refused:
            raise Refused("the server did not shut down in 15 min. This tool never forces it off: "
                          "look at its console, shut it down, then rerun") from None
        info["power"] = "Off"
    else:
        out("plan: wait for the server to shut down (up to 15 min, never forced)")


def manual_media_steps(name, rel, out):
    out(f"manual: USB stick, macOS: diskutil list, then diskutil unmountDisk /dev/diskN, then")
    out(f"manual:   sudo dd if={rel} of=/dev/rdiskN bs=4m, then diskutil eject /dev/diskN")
    out(f"manual: or write {rel} with balenaEtcher, or mount it as virtual CD in the BMC web UI")
    out(f"manual: the ISO holds the root password hash. Afterwards: make provision-clean NAME={name}")


def redfish_steps(name, m, rf, info, cd, sysp, reset, want_boot, iso, rel, static_ip, apply, media_ready, word, out):
    def act(method, path, body):
        out(f"{word}: {method} {path} {json.dumps(body, sort_keys=True)}")
        if apply:
            rf.request(method, path, body)

    def power():
        return rf.get(sysp).get("PowerState")

    srv = None
    inserted = False
    if m["media"] == "manual":
        manual_media_steps(name, rel, out)
        if apply and not media_ready:
            raise Refused("attach the media first, then add -e provision_media_ready=true")
    try:
        if m["media"] == "redfish":
            if apply:
                bind = local_address_towards(m["bmc"]["address"])
                srv, url = serve_iso(iso, bind, int(os.environ.get("PROVISION_HTTP_PORT", "0")))
                out(f"do: serve {rel} over HTTP on {bind}:{srv.server_address[1]} at a random path")
            else:
                url = f"http://<this Mac's LAN address>:<port>/<random>/{name}.iso"
                out(f"plan: serve {rel} over HTTP on this Mac's LAN address, for this run only")
            body = {"Image": url, "Inserted": True, "WriteProtected": True}
            if cd and cd["protocols"]:
                body["TransferProtocolType"] = "HTTP"
            act("POST", cd["insert"] if cd else "<virtual CD>/Actions/VirtualMedia.InsertMedia", body)
            inserted = apply
        act("PATCH", sysp, {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": want_boot}})
        act("POST", reset, {"ResetType": "On"})
        if apply:
            wait_for("the server to power on", lambda: power() == "On", 10 * 60, 10, out)
            wait_for("the installer to power the server off", lambda: power() == "Off", 90 * 60, 30, out)
        else:
            out("plan: wait for the installer to power the server off (up to 90 min)")
        if m["media"] == "redfish":
            act("POST", cd["eject"] if cd else "<virtual CD>/Actions/VirtualMedia.EjectMedia", {})
            inserted = False
            out(f"{word}: stop serving and delete {rel}")
            if apply:
                srv.shutdown()
                srv = None
                os.remove(iso)
            act("POST", reset, {"ResetType": "On"})
        else:
            out(f"manual: remove the media and power the server on, then: make provision-clean NAME={name}")
        if static_ip:
            if apply:
                wait_for(f"SSH on {static_ip}:22", lambda: ssh_open(static_ip), 30 * 60, 15, out)
            else:
                out(f"plan: wait for SSH on {static_ip}:22")
        handoff(name, m, out)
    finally:
        if inserted:
            out("cleanup: eject the virtual CD")
            try:
                rf.request("POST", cd["eject"], {})
            except Refused as e:
                out(f"cleanup: eject failed ({e}). Eject it in the BMC web UI")
        if srv:
            srv.shutdown()
            out(f"cleanup: stopped serving. Delete the ISO when done: make provision-clean NAME={name}")
    return 0


def ipmi_steps(name, m, ip, iso, rel, static_ip, apply, media_ready, word, out):
    shown = Ipmi(m["bmc"]["address"], "", "")

    def act(args):
        out(f"{word}: " + shown.shown(args))
        if apply:
            ip.call(args)

    if m.get("boot_device") == "usb":
        raise Refused("IPMI has no USB boot device. Pick the stick in the boot menu, or set bmc.type none")
    manual_media_steps(name, rel, out)
    if apply and not media_ready:
        raise Refused("attach the media first, then add -e provision_media_ready=true")
    act(["chassis", "bootdev", "cdrom"] + (["options=efiboot"] if m["boot_mode"] == "uefi" else []))
    act(["chassis", "power", "on"])
    if apply:
        wait_for("the server to power on", lambda: ip.power() == "On", 10 * 60, 10, out)
        wait_for("the installer to power the server off", lambda: ip.power() == "Off", 90 * 60, 30, out)
    else:
        out("plan: wait for the installer to power the server off (up to 90 min)")
    out(f"manual: remove the media and power the server on, then: make provision-clean NAME={name}")
    if static_ip:
        if apply:
            wait_for(f"SSH on {static_ip}:22", lambda: ssh_open(static_ip), 30 * 60, 15, out)
        else:
            out(f"plan: wait for SSH on {static_ip}:22")
    handoff(name, m, out)
    return 0


# --- media pxe: a temporary netboot service on the Proxmox host --------------------------------

NETBOOT_BASE = "/var/tmp/anvil-provision"

# Exit 0 when the netboot payload of $1 is there. Read-only.
NETBOOT_PAYLOAD_CHECK = r"""p=/var/tmp/anvil-provision/pxe-$1
[ -s "$p/linux26" ] && [ -s "$p/initrd" ]
"""

# Starts the netboot service. Args: name mac addr prefix port token max_seconds.
# dnsmasq: proxyDHCP only (dhcp-range ... proxy, no DNS), on the vmbr bridge that holds the
# uplink address, answering only the target MAC. TFTP serves iPXE and boot.ipxe from a
# directory named after that MAC (tftp-unique-root=mac), so no other client gets them.
NETBOOT_START = r"""set -euo pipefail
name=$1 mac=$2 addr=$3 prefix=$4 port=$5 token=$6 maxsec=$7
unit=anvil-netboot-$name
payload=/var/tmp/anvil-provision/pxe-$name
ipxe=/var/tmp/anvil-provision/ipxe
run=/run/$unit
die() { echo "netboot: $*" >&2; exit 3; }
[ -s "$payload/linux26" ] && [ -s "$payload/initrd" ] || die "no netboot payload for $name: make provision-iso NAME=$name"
[ -s "$ipxe/ipxe.efi" ] && [ -s "$ipxe/undionly.kpxe" ] || die "no iPXE binaries: make provision-iso NAME=$name"
[ -s "$run/provision.py" ] || die "provision.py was not copied"
ifc=$(ip -o -4 addr show | awk -v a="$addr" '{split($4, p, "/"); if (p[1] == a) print $2}' | head -n 1)
[ -n "$ifc" ] || die "no interface holds the uplink address"
case $ifc in vmbr[0-9]*) ;; *) die "the uplink address is on $ifc, not a vmbr bridge: refused" ;; esac
if ip -d link show "$ifc" | grep -qw vlan; then die "$ifc is a VLAN interface: refused"; fi
net=$(python3 -c 'import ipaddress, sys; print(ipaddress.ip_interface(sys.argv[1]).network.network_address)' "$addr/$prefix")
for u in "$unit-dhcp" "$unit-http"; do
  if systemctl is-active --quiet "$u"; then die "$u is already running"; fi
done
if ss -Hlnt "sport = :$port" | grep -q .; then die "TCP port $port is in use"; fi
if ss -Hlnu "sport = :69" | grep -q .; then die "UDP port 69 (TFTP) is in use"; fi
macdir=$(printf '%s' "$mac" | tr ':' '-')
install -d -m 755 "$run/tftp" "$run/tftp/$macdir"
install -m 644 "$ipxe/ipxe.efi" "$ipxe/undionly.kpxe" "$run/tftp/$macdir/"
cat >"$run/tftp/$macdir/boot.ipxe" <<EOF
#!ipxe
echo anvil: Proxmox VE automated installer over HTTP
kernel http://$addr:$port/$token/linux26 initrd=initrd ro ramdisk_size=16777216 rw quiet splash=silent proxmox-start-auto-installer
initrd http://$addr:$port/$token/initrd
boot
EOF
chmod 644 "$run/tftp/$macdir/boot.ipxe"
cat >"$run/dnsmasq.conf" <<EOF
port=0
interface=$ifc
bind-interfaces
pid-file=$run/dnsmasq.pid
dhcp-leasefile=$run/dnsmasq.leases
log-dhcp
dhcp-range=$net,proxy
dhcp-host=$mac,set:anvil
dhcp-ignore=tag:!anvil
dhcp-userclass=set:ipxe,iPXE
pxe-service=tag:!ipxe,x86PC,"anvil",undionly.kpxe
pxe-service=tag:!ipxe,x86-64_EFI,"anvil",ipxe.efi
pxe-service=tag:!ipxe,BC_EFI,"anvil",ipxe.efi
pxe-service=tag:ipxe,x86PC,"anvil",boot.ipxe
pxe-service=tag:ipxe,x86-64_EFI,"anvil",boot.ipxe
pxe-service=tag:ipxe,BC_EFI,"anvil",boot.ipxe
enable-tftp
tftp-root=$run/tftp
tftp-unique-root=mac
EOF
systemd-run --quiet --collect --unit="$unit-http" -p RuntimeMaxSec="$maxsec" \
  /usr/bin/python3 -I "$run/provision.py" serve --bind "$addr" --port "$port" --token "$token" \
  --file "linux26=$payload/linux26" --file "initrd=$payload/initrd"
systemd-run --quiet --collect --unit="$unit-dhcp" -p RuntimeMaxSec="$maxsec" \
  /usr/sbin/dnsmasq --keep-in-foreground --conf-file="$run/dnsmasq.conf"
sleep 2
if ! systemctl is-active --quiet "$unit-http" || ! systemctl is-active --quiet "$unit-dhcp"; then
  journalctl -u "$unit-dhcp" -u "$unit-http" -o cat -n 20 --no-pager >&2 || true
  die "the netboot service did not start"
fi
echo "$ifc"
"""

# Stops and removes the netboot service. Args: name.
NETBOOT_STOP = r"""name=$1
unit=anvil-netboot-$name
systemctl stop "$unit-dhcp" "$unit-http" 2>/dev/null || true
systemctl reset-failed "$unit-dhcp" "$unit-http" 2>/dev/null || true
rm -rf "/run/$unit"
if systemctl is-active --quiet "$unit-dhcp" || systemctl is-active --quiet "$unit-http"; then exit 1; fi
"""

# Deletes the payload (kernel, and the initrd with the ISO and its password hash). Args: name.
NETBOOT_DELETE = r"""rm -rf "/var/tmp/anvil-provision/pxe-$1"
"""


def netboot_host(site):
    host = os.environ.get("PROVISION_NETBOOT_HOST")
    if host:
        return host
    return "root@" + str((site.get("pve") or {}).get("ip") or os.environ.get("PVE_IP"))


def remote(host, script, *args, input_text=None, check=True):
    cmd = ["ssh", "-o", "BatchMode=yes", host, "bash -s -- " + " ".join(shlex.quote(str(a)) for a in args)]
    r = subprocess.run(cmd, input=script if input_text is None else input_text, capture_output=True, text=True, timeout=300, check=False)
    if check and r.returncode != 0:
        raise Refused(f"on {host}: " + (r.stderr.strip().splitlines() or [f"exit {r.returncode}"])[-1])
    return r


class RedfishPower:
    def __init__(self, rf, sysp, reset, apply, word, out):
        self.rf, self.sysp, self.reset, self.apply, self.word, self.out = rf, sysp, reset, apply, word, out

    def act(self, method, path, body):
        self.out(f"{self.word}: {method} {path} {json.dumps(body, sort_keys=True)}")
        if self.apply:
            self.rf.request(method, path, body)

    def boot_once_pxe(self):
        self.act("PATCH", self.sysp, {"Boot": {"BootSourceOverrideEnabled": "Once", "BootSourceOverrideTarget": "Pxe"}})
        self.act("POST", self.reset, {"ResetType": "On"})

    def power_on(self):
        self.act("POST", self.reset, {"ResetType": "On"})

    def power(self):
        return self.rf.get(self.sysp).get("PowerState")


class IpmiPower:
    def __init__(self, m, ip, apply, word, out):
        self.m, self.ip, self.apply, self.word, self.out = m, ip, apply, word, out
        self.shown = Ipmi("", "", "").shown

    def act(self, args):
        self.out(f"{self.word}: " + self.shown(args))
        if self.apply:
            self.ip.call(args)

    def boot_once_pxe(self):
        self.act(["chassis", "bootdev", "pxe"] + (["options=efiboot"] if self.m["boot_mode"] == "uefi" else []))
        self.act(["chassis", "power", "on"])

    def power_on(self):
        self.act(["chassis", "power", "on"])

    def power(self):
        return self.ip.power()


def pxe_steps(site, name, m, ops, boot_once, power_on, static_ip, apply, word, out):
    """ops: RedfishPower, IpmiPower, or None (bmc.type none: the operator powers on)."""
    pve = site.get("pve") or {}
    addr, prefix = pve.get("uplink_ip"), pve.get("uplink_prefix")
    if not addr or not prefix:
        raise Refused("media pxe needs site.pve.uplink_ip and uplink_prefix (the home network the ONT serves)")
    host = netboot_host(site)
    port = int(os.environ.get("PROVISION_NETBOOT_PORT", "18199"))
    unit = f"anvil-netboot-{name}"
    mac = m["boot_mac"]
    out(f"{word}: on the Proxmox host, start {unit}-dhcp: dnsmasq proxyDHCP (no addresses, no DNS) and TFTP on the bridge with the uplink address, PXE answers for {mac} only")
    out(f"{word}: on the Proxmox host, start {unit}-http: the installer kernel and initrd over HTTP on the uplink address, port {port}, at a random path")
    started = False
    payload_kept = True
    try:
        if apply:
            here = os.path.abspath(__file__)
            with open(here, encoding="utf-8") as f:
                r = subprocess.run(["ssh", "-o", "BatchMode=yes", host,
                                    f"install -d -m 755 /run/{unit} && cat > /run/{unit}/provision.py"],
                                   stdin=f, capture_output=True, text=True, timeout=120, check=False)
            if r.returncode != 0:
                raise Refused(f"on {host}: could not copy provision.py")
            since = int(time.time()) - 5
            started = True
            ifc = remote(host, NETBOOT_START, name, mac, addr, prefix, port, secrets.token_urlsafe(16), 4 * 3600).stdout.strip()
            out(f"do: netboot is up on {ifc}")
        if ops:
            boot_once()
        else:
            out("manual: power the server on and pick network boot (PXE) in its boot menu")

        def served():
            r = remote(host, f'journalctl -u {unit}-http --since @{since} -o cat --no-pager | grep -cx "served initrd" || true\n', check=False)
            return r.stdout.strip() not in ("", "0")

        if apply:
            wait_for("the installer kernel and initrd to be served", served, (30 if ops else 120) * 60, 10, out)
        else:
            out("plan: wait for the installer kernel and initrd to be served")
        out(f"{word}: stop and remove {unit}-dhcp and {unit}-http, delete the netboot payload")
        if apply:
            remote(host, NETBOOT_STOP, name)
            started = False
            remote(host, NETBOOT_DELETE, name)
            payload_kept = False
        if ops:
            if apply:
                wait_for("the installer to power the server off", lambda: ops.power() == "Off", 90 * 60, 30, out)
            else:
                out("plan: wait for the installer to power the server off (up to 90 min)")
            power_on()
        else:
            out("manual: the installer powers the server off when it is done. Then power it on")
        if static_ip:
            if apply:
                wait_for(f"SSH on {static_ip}:22", lambda: ssh_open(static_ip), (30 if ops else 150) * 60, 15, out)
            else:
                out(f"plan: wait for SSH on {static_ip}:22")
        handoff(name, m, out)
    finally:
        if apply and started:
            out("cleanup: stop and remove the netboot service")
            if remote(host, NETBOOT_STOP, name, check=False).returncode != 0:
                out(f"cleanup: FAILED. On the Proxmox host: systemctl stop {unit}-dhcp {unit}-http")
        if apply and payload_kept:
            out("cleanup: delete the netboot payload")
            if remote(host, NETBOOT_DELETE, name, check=False).returncode != 0:
                out(f"cleanup: FAILED. Delete {NETBOOT_BASE}/pxe-{name} on the Proxmox host")
    return 0


# --- CLI --------------------------------------------------------------------------------------

def _interrupt(signum, frame):
    raise KeyboardInterrupt


def main(argv=None):
    ap = argparse.ArgumentParser(prog="provision.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("answer", help="print the answer file (root password on stdin)")
    a.add_argument("--name", required=True)
    a.add_argument("--ssh-key", default="~/.ssh/id_ed25519.pub")
    c = sub.add_parser("check", help="check the machine entry and the guard, no network")
    c.add_argument("--name", required=True)
    g = sub.add_parser("get", help="print one field of the checked machine entry")
    g.add_argument("--name", required=True)
    g.add_argument("--key", required=True)
    sv = sub.add_parser("serve", help="serve files over HTTP at /<token>/<name> until stopped")
    sv.add_argument("--bind", required=True)
    sv.add_argument("--port", type=int, required=True)
    sv.add_argument("--token", required=True)
    sv.add_argument("--file", action="append", required=True, metavar="NAME=PATH")
    r = sub.add_parser("run", help="a dry run, or the install with -e provision_confirm=<name>")
    r.add_argument("--name", required=True)
    r.add_argument("-e", dest="opts", action="append", default=[], metavar="KEY=VALUE")
    args = ap.parse_args(argv)
    try:
        if args.cmd == "serve":
            files = dict(f.split("=", 1) for f in args.file)
            for pth in files.values():
                if not os.path.isfile(pth):
                    raise Refused(f"no such file: {pth}")
            srv = serve_files(files, args.bind, args.port, args.token)
            srv.announce = True
            print(f"serving {len(files)} files on {args.bind}:{srv.server_address[1]}", flush=True)
            threading.Event().wait()
        site = load_site()
        if args.cmd == "get":
            v = machine(site, args.name).get(args.key)
            print(v if isinstance(v, str) else json.dumps(v))
            return 0
        if args.cmd == "answer":
            plain = sys.stdin.readline().rstrip("\n")
            text = answer(site, args.name, hash_password(plain), read_ssh_keys(args.ssh_key))
            del plain
            sys.stdout.write(text)
        elif args.cmd == "check":
            m = machine(site, args.name)
            static_guard(site, args.name, m)
            print(f"{args.name}: ok (bmc {m['bmc']['type']}, media {m['media']}, {m['disk_setup']['filesystem']})")
        elif args.cmd == "run":
            # Ctrl-C, a closed terminal or a kill all run the cleanup (finally blocks).
            for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                signal.signal(sig, _interrupt)
            opts = {}
            for o in args.opts:
                k, sep, v = o.partition("=")
                if not sep:
                    raise Refused(f"-e takes KEY=VALUE, not {o!r}")
                opts[k.strip()] = v.strip()
            return run(site, args.name, opts, out=lambda line: print(line, flush=True))
    except Refused as e:
        print(f"provision: refused: {e}", file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        print("provision: interrupted", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
