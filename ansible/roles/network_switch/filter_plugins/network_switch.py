# The Cisco SG300 switch's command plan (role network_switch). Pure Python, no Ansible
# imports beyond the error type, so tests/integration/test_switch.sh runs it directly.
#
# switch_state(text) splits the output of scripts/switch-cli.sh ("@@@ <command>" before
# each command's output) into {command: output}.
# switch_plan(outputs, ports, vlans, native_vlan, keep_ports, dhcp_snooping) returns the
# lines to send. Only the ports named in `ports` appear in the plan. A port in `keep_ports`
# (the router uplink, the access point) may not be in `ports` and must not be protected
# today. The one exception is DHCP snooping: its trusted ports (where a real DHCP server
# is, such as the router uplink) are trusted even when they are keep_ports, because trust
# only lets DHCP replies through.
import re

try:
    from ansible.errors import AnsibleFilterError
except ImportError:  # plain Python (tests)
    class AnsibleFilterError(Exception):
        pass

PORT_RE = re.compile(r"^gi([1-9]|[1-4][0-9]|5[0-2])$")
ROLES = ("trunk", "protected")
NAME_RE = re.compile(r"^[a-z][a-z0-9]{0,15}$")


def switch_state(text):
    out = {}
    cmd = None
    for line in (text or "").splitlines():
        if line.startswith("@@@ "):
            cmd = line[4:].strip()
            out[cmd] = []
        elif cmd is not None:
            out[cmd].append(line)
    return {k: "\n".join(v) for k, v in out.items()}


def parse_vlans(text):
    """show vlan -> {id: name}. Continuation rows (more ports) start with no VLAN id."""
    vlans = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(\d{1,4})\s+(\S+)\s", line + " ")
        if m:
            vlans[int(m.group(1))] = m.group(2)
    return vlans


def parse_switchport(text):
    """show interfaces switchport <port> -> mode, native VLAN, {vlan: Tagged|Untagged}."""
    mode = re.search(r"Port Mode:\s*(\S+)", text)
    native = re.search(r"NATIVE\s*\)\s*:\s*(\d+)", text)
    members = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(\d{1,4})\s+.*?\s(Tagged|Untagged)\s+\S+\s*$", line)
        if m:
            members[int(m.group(1))] = m.group(2)
    if not mode or not members:
        raise AnsibleFilterError("switch: could not read show interfaces switchport output")
    return {
        "mode": mode.group(1).lower(),
        "native": int(native.group(1)) if native else None,
        "members": members,
    }


def parse_protected(text):
    """show interfaces protected-ports -> {port: True if protected}."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(gi\d+|Po\d+)\s+(Protected|Unprotected)\s*$", line)
        if m:
            out[m.group(1)] = m.group(2) == "Protected"
    if not out:
        raise AnsibleFilterError("switch: could not read show interfaces protected-ports output")
    return out


def parse_snooping(text):
    """show ip dhcp snooping -> enabled, the VLANs it covers, the trusted ports."""
    if "DHCP snooping is" not in text:
        raise AnsibleFilterError("switch: could not read show ip dhcp snooping output")
    enabled = re.search(r"DHCP snooping is Enabled", text) is not None
    vlans = set()
    m = re.search(r"configured on following VLANs:\s*([0-9,\- ]*)", text)
    for part in (m.group(1) if m else "").replace(" ", "").split(","):
        if re.fullmatch(r"\d+-\d+", part):
            a, b = part.split("-")
            vlans.update(range(int(a), int(b) + 1))
        elif part.isdigit():
            vlans.add(int(part))
    trusted = {m.group(1) for m in re.finditer(r"^\s*(gi\d+|Po\d+)\s+Yes\s*$", text, re.M)}
    return {"enabled": enabled, "vlans": vlans, "trusted": trusted}


def _snooping(conf, native_vlan):
    """site.network.switch.dhcp_snooping -> (trusted ports, VLANs), or None when absent."""
    if not conf:
        return None
    trusted = [str(p) for p in conf.get("trusted") or []]
    if not trusted:
        raise AnsibleFilterError(
            "site.network.switch.dhcp_snooping.trusted must name the ports of the real DHCP "
            "servers (the router uplink at least): with none, every DHCP reply is dropped")
    for p in trusted:
        if not PORT_RE.match(p):
            raise AnsibleFilterError("site.network.switch.dhcp_snooping: bad port name %s" % p)
    vlans = sorted(int(v) for v in (conf.get("vlans") or [native_vlan]))
    return trusted, vlans


def _roles(ports):
    if not isinstance(ports, dict) or not ports:
        raise AnsibleFilterError("site.network.switch.ports must map ports to roles")
    out = {}
    for port, roles in ports.items():
        roles = [roles] if isinstance(roles, str) else list(roles or [])
        if not PORT_RE.match(str(port)):
            raise AnsibleFilterError("site.network.switch.ports: bad port name %s" % port)
        bad = [r for r in roles if r not in ROLES]
        if not roles or bad:
            raise AnsibleFilterError(
                "site.network.switch.ports.%s: roles must be among %s" % (port, ", ".join(ROLES)))
        out[str(port)] = roles
    return out


def _vlan_ids(ids):
    return ",".join(str(i) for i in sorted(ids))


def switch_read_commands(ports, dhcp_snooping=None):
    """The show commands whose output switch_plan needs."""
    cmds = ["show vlan", "show interfaces protected-ports"]
    cmds += ["show interfaces switchport %s" % p for p in sorted(_roles(ports), key=lambda p: int(p[2:]))]
    if dhcp_snooping:
        cmds.append("show ip dhcp snooping")
    return cmds


def switch_plan(outputs, ports, vlans, native_vlan=1, keep_ports=None, dhcp_snooping=None):
    roles = _roles(ports)
    snoop = _snooping(dhcp_snooping, int(native_vlan))
    keep = [str(p) for p in (keep_ports or [])]
    for p in keep:
        if not PORT_RE.match(p):
            raise AnsibleFilterError("site.network.switch.keep_ports: bad port name %s" % p)
    clash = sorted(set(keep) & set(roles))
    if clash:
        raise AnsibleFilterError(
            "site.network.switch: %s is in both ports and keep_ports" % ", ".join(clash))

    want = {}
    for v in vlans or []:
        tag, name = int(v["tag"]), str(v["name"])
        if not 2 <= tag <= 4094 or not NAME_RE.match(name):
            raise AnsibleFilterError("switch: bad VLAN %s %s" % (tag, name))
        want[tag] = name
    native_vlan = int(native_vlan)
    if native_vlan in want:
        raise AnsibleFilterError("switch: the native VLAN may not also be a tagged VLAN")

    have_vlans = parse_vlans(outputs["show vlan"])
    protected = parse_protected(outputs["show interfaces protected-ports"])
    for p in keep:
        if protected.get(p):
            raise AnsibleFilterError("switch: %s (keep_ports) is protected today. Fix that by hand first" % p)

    lines = []
    if any("trunk" in r for r in roles.values()) and want:
        missing = [t for t in want if t not in have_vlans]
        if missing:
            lines += ["vlan database", "vlan %s" % _vlan_ids(missing), "exit"]
        for tag in sorted(want):
            if have_vlans.get(tag) != want[tag]:
                lines += ["interface vlan %d" % tag, "name %s" % want[tag], "exit"]

    for port in sorted(roles, key=lambda p: int(p[2:])):
        sp = parse_switchport(outputs["show interfaces switchport %s" % port])
        body = []
        if "trunk" in roles[port]:
            if sp["mode"] != "trunk":
                body.append("switchport mode trunk")
            if sp["native"] != native_vlan:
                body.append("switchport trunk native vlan %d" % native_vlan)
            elif sp["members"].get(native_vlan) != "Untagged":
                raise AnsibleFilterError(
                    "switch: %s has native VLAN %d but not untagged. Fix that by hand first"
                    % (port, native_vlan))
            add = [t for t in want if sp["members"].get(t) != "Tagged"]
            if add:
                body.append("switchport trunk allowed vlan add %s" % _vlan_ids(add))
        if "protected" in roles[port] and not protected.get(port, False):
            body.append("switchport protected-port")
        if body:
            lines += ["interface %s" % port] + body + ["exit"]

    # DHCP snooping: the trusted ports first, then the VLANs, then the switch-wide switch, so
    # the router uplink is never untrusted while snooping is on.
    snoop_lines = []
    if snoop:
        trusted, svlans = snoop
        have = parse_snooping(outputs["show ip dhcp snooping"])
        for port in sorted(trusted, key=lambda p: int(p[2:])):
            if port not in have["trusted"]:
                snoop_lines += ["interface %s" % port, "ip dhcp snooping trust", "exit"]
        for v in svlans:
            if v not in have["vlans"]:
                snoop_lines.append("ip dhcp snooping vlan %d" % v)
        if not have["enabled"]:
            snoop_lines.append("ip dhcp snooping")
    lines += snoop_lines

    named = set(re.findall(r"\bgi\d+\b", "\n".join(lines)))
    touched = named - (set(snoop[0]) if snoop else set())
    if not touched <= set(roles):
        raise AnsibleFilterError("switch: the plan names ports outside site.network.switch.ports")
    return ["configure terminal"] + lines + ["end"] if lines else []


class FilterModule(object):
    def filters(self):
        return {
            "switch_state": switch_state,
            "switch_read_commands": switch_read_commands,
            "switch_plan": switch_plan,
        }
