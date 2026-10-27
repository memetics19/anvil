"""The one vendor-specific part of provisioning (docs/provisioning.md, RAID controller):
Dell iDRAC 7, 8 and 9 over WS-Man (the DCIM classes). It runs only for a machine with
controller: {vendor: dell, mode: nonraid}.

It reads the physical disks and turns the ones in Ready state into Non-RAID disks, so the
installer and ZFS see each disk on its own. One Lifecycle Controller job per controller
applies it during one reboot. A disk inside a RAID volume is refused: this never deletes
or changes a RAID volume. Basic auth on every request, no session, nothing printed but
disk names and states.
"""
import base64
import os
import re
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET

DCIM = "http://schemas.dell.com/wbem/wscim/1/cim-schema/2/"
RAID_SERVICE = {
    "CreationClassName": "DCIM_RAIDService",
    "Name": "DCIM:RAIDService",
    "SystemCreationClassName": "DCIM_ComputerSystem",
    "SystemName": "DCIM:ComputerSystem",
}
# DCIM_PhysicalDiskView.RaidStatus
STATES = {"0": "Unknown", "1": "Ready", "2": "Online", "3": "Foreign", "4": "Offline",
          "5": "Blocked", "6": "Failed", "7": "Degraded", "8": "Non-RAID"}


class DellError(Exception):
    """A refusal, with a message for the operator."""


def _local(tag):
    return tag.rsplit("}", 1)[-1]


class WSMan:
    def __init__(self, address, user, password, ctx, timeout=150):
        self.url = os.environ.get("PROVISION_TEST_WSMAN_URL") or f"https://{address}/wsman"  # the override is for tests only
        self.to = f"https://{address}/wsman"
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()
        self.ctx, self.timeout = ctx, timeout

    def _post(self, uri, action, body, selectors=None):
        sel = ""
        if selectors:
            sel = "<w:SelectorSet>" + "".join(
                f'<w:Selector Name="{k}">{v}</w:Selector>' for k, v in selectors.items()) + "</w:SelectorSet>"
        env = (
            '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            'xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
            'xmlns:n="http://schemas.xmlsoap.org/ws/2004/09/enumeration" '
            'xmlns:w="http://schemas.dmtf.org/wbem/wsman/1/wsman.xsd" '
            f'xmlns:p="{uri}"><s:Header><a:To>{self.to}</a:To>'
            f'<w:ResourceURI s:mustUnderstand="true">{uri}</w:ResourceURI>'
            "<a:ReplyTo><a:Address>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</a:Address></a:ReplyTo>"
            f'<a:Action s:mustUnderstand="true">{action}</a:Action>'
            '<w:MaxEnvelopeSize s:mustUnderstand="true">512000</w:MaxEnvelopeSize>'
            f"<a:MessageID>uuid:anvil-provision</a:MessageID><w:OperationTimeout>PT120S</w:OperationTimeout>{sel}"
            f"</s:Header><s:Body>{body}</s:Body></s:Envelope>")
        req = urllib.request.Request(self.url, data=env.encode(), method="POST")
        req.add_header("Authorization", self.auth)
        req.add_header("Content-Type", "application/soap+xml;charset=UTF-8")
        try:
            with urllib.request.urlopen(req, context=self.ctx, timeout=self.timeout) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:
            raise DellError(f"WS-Man {_local(action)}: HTTP {e.code}") from None
        except (urllib.error.URLError, OSError) as e:
            raise DellError(f"WS-Man {_local(action)}: {getattr(e, 'reason', e)}") from None
        try:
            root = ET.fromstring(text)
        except ET.ParseError:
            raise DellError(f"WS-Man {_local(action)}: not XML") from None
        for el in root.iter():
            if _local(el.tag) == "Fault":
                reason = " ".join(t.strip() for t in el.itertext() if t.strip())
                raise DellError(f"WS-Man {_local(action)}: fault: {reason[:200]}")
        return root

    @staticmethod
    def _fields(el):
        return {_local(c.tag): (c.text or "").strip() for c in el}

    def enumerate(self, cls):
        uri = DCIM + cls
        root = self._post(uri, "http://schemas.xmlsoap.org/ws/2004/09/enumeration/Enumerate",
                          "<n:Enumerate><w:OptimizeEnumeration/><w:MaxElements>64</w:MaxElements></n:Enumerate>")
        if not any(_local(e.tag) == "EndOfSequence" for e in root.iter()):
            raise DellError(f"WS-Man {cls}: more than 64 items, not supported")
        items = [e for e in root.iter() if _local(e.tag) == "Items"]
        return [self._fields(c) for it in items for c in it]

    def get(self, cls, selectors):
        root = self._post(DCIM + cls, "http://schemas.xmlsoap.org/ws/2004/09/transfer/Get", "", selectors)
        body = next(e for e in root.iter() if _local(e.tag) == "Body")
        return self._fields(body[0]) if len(body) else {}

    def invoke(self, cls, method, selectors, inputs):
        uri = DCIM + cls
        args = "".join(f"<p:{k}>{v}</p:{k}>" for k, v in inputs)
        root = self._post(uri, f"{uri}/{method}", f"<p:{method}_INPUT>{args}</p:{method}_INPUT>", selectors)
        out, jobs = {}, []
        for e in root.iter():
            name = _local(e.tag)
            if name in ("ReturnValue", "Message", "MessageID", "RebootRequired"):
                out[name] = (e.text or "").strip()
            if e.text and re.fullmatch(r"JID_\d+", e.text.strip()):
                jobs.append(e.text.strip())
        out["job"] = jobs[0] if jobs else None
        return out


def disks(ws):
    """[(fqdd, state name, model)] of every physical disk."""
    return [(d.get("FQDD", "?"), STATES.get(d.get("RaidStatus", ""), d.get("RaidStatus", "?")), d.get("Model", "").strip())
            for d in ws.enumerate("DCIM_PhysicalDiskView")]


def nonraid(ws, apply, word, out, wait_for):
    """Ready disks to Non-RAID. Returns True when it ran a job (the server rebooted)."""
    out("read: WS-Man enumerate DCIM_PhysicalDiskView (the disks' RAID state)")
    found = disks(ws)
    todo, bad = {}, []
    for fqdd, state, model in found:
        if state == "Non-RAID":
            continue
        if state == "Ready":
            todo.setdefault(fqdd.rsplit(":", 1)[-1], []).append(fqdd)
        elif state in ("Online", "Degraded"):
            bad.append(f"{fqdd} ({model}) is in a RAID volume. anvil never deletes one: delete the volume in the iDRAC, then rerun")
        else:
            bad.append(f"{fqdd} ({model}) is {state}. Fix it in the iDRAC, then rerun")
    if bad:
        raise DellError("\n  ".join(["the RAID controller is not ready for pass-through:"] + bad))
    if not todo:
        out(f"read: all {len(found)} disks are Non-RAID")
        return False
    for ctrl, pds in sorted(todo.items()):
        out(f"{word}: WS-Man DCIM_RAIDService.ConvertToNonRAID, {len(pds)} Ready disks on {ctrl}")
        out(f"{word}: WS-Man DCIM_RAIDService.CreateTargetedConfigJob {ctrl}, a graceful reboot now")
        if not apply:
            out("plan: wait for the Lifecycle Controller job (the server reboots once, about 10 min)")
            continue
        r = ws.invoke("DCIM_RAIDService", "ConvertToNonRAID", RAID_SERVICE, [("PDArray", x) for x in pds])
        if r.get("ReturnValue") != "0":
            raise DellError(f"ConvertToNonRAID on {ctrl}: {r.get('Message') or r.get('ReturnValue')}")
        r = ws.invoke("DCIM_RAIDService", "CreateTargetedConfigJob", RAID_SERVICE,
                      [("Target", ctrl), ("RebootJobType", "3"), ("ScheduledStartTime", "TIME_NOW")])
        if r.get("ReturnValue") != "4096" or not r["job"]:
            raise DellError(f"CreateTargetedConfigJob on {ctrl}: {r.get('Message') or r.get('ReturnValue')}")
        jid = r["job"]
        out(f"do: job {jid} scheduled")
        state = {}

        def done():
            state.update(ws.get("DCIM_LifecycleJob", {"InstanceID": jid}))
            return state.get("JobStatus", "") in ("Completed", "Failed", "Completed with Errors")

        wait_for(f"job {jid} (the server reboots once)", done, 40 * 60, 30, out)
        if state.get("JobStatus") != "Completed":
            raise DellError(f"job {jid}: {state.get('JobStatus')}: {state.get('Message', '')}")
        out(f"do: job {jid} completed")
    if apply:
        left = [f for f, s, _ in disks(ws) if s != "Non-RAID"]
        if left:
            raise DellError(f"after the job, {len(left)} disks are still not Non-RAID")
        out(f"read: all {len(found)} disks are Non-RAID")
    return apply
