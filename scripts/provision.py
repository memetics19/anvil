#!/usr/bin/env python3
"""Bare-metal provisioning of a Proxmox VE server with the automated installer
(docs/provisioning.md). Brand agnostic: the answer file is plain Proxmox, the BMC is
driven only through standard DMTF Redfish or plain IPMI.

  provision.py answer --name <box> [--ssh-key <file>]   root password on stdin
      prints the installer answer file (TOML) for site.provision.machines.<box>
  provision.py check --name <box>
      checks the machine entry and the guard against the current server, no network

The site dict comes from $PROVISION_SITE_FILE (JSON or YAML, with or without a top-level
`site` key) or else from $TF_VAR_site_json (scripts/env.sh). Nothing secret is printed:
the answer file holds only the password hash, and the plaintext stays in Vault.
"""
import argparse
import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys


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
    if m["media"] not in ("redfish", "manual"):
        raise Refused(f"{name}: media is redfish or manual")
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
    m["disk_setup"] = disk_setup(name, m.get("disks"))
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


# --- CLI --------------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(prog="provision.py", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("answer", help="print the answer file (root password on stdin)")
    a.add_argument("--name", required=True)
    a.add_argument("--ssh-key", default="~/.ssh/id_ed25519.pub")
    c = sub.add_parser("check", help="check the machine entry and the guard, no network")
    c.add_argument("--name", required=True)
    args = ap.parse_args(argv)
    try:
        site = load_site()
        if args.cmd == "answer":
            plain = sys.stdin.readline().rstrip("\n")
            text = answer(site, args.name, hash_password(plain), read_ssh_keys(args.ssh_key))
            del plain
            sys.stdout.write(text)
        elif args.cmd == "check":
            m = machine(site, args.name)
            static_guard(site, args.name, m)
            print(f"{args.name}: ok (bmc {m['bmc']['type']}, media {m['media']}, {m['disk_setup']['filesystem']})")
    except Refused as e:
        print(f"provision: refused: {e}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
