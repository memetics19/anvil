#!/usr/bin/env python3
"""XMLTV guide for the IPTV lineup, written to stdout.

Channels come from IPTV_EPG_CHANNELS ([{"id", "name", "dishtv"}]), set by the role from
iptv/channels.yml. A channel with a "dishtv" id gets today's and tomorrow's programmes
from Dish TV's public programme guide (the source iptv-org/epg uses for dishtv.in). A
channel without one, or whose guide cannot be fetched, gets a placeholder: one
"<name> Live" programme per day, so players still list it cleanly. Exits 0 whenever it
printed a guide; a summary per channel goes to stderr.
"""
import datetime as dt
import json
import os
import sys
import urllib.request
import xml.etree.ElementTree as ET

IST = dt.timezone(dt.timedelta(hours=5, minutes=30))
DAYS = int(os.environ.get("IPTV_EPG_DAYS", "2"))
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"
SIGNIN = "https://www.dishtv.in/services/epg/signin"
PROGRAMS = "https://epg.mysmartstick.com/dishtv/api/v1/epg/entities/programs"


def post(url, headers, body=None):
    req = urllib.request.Request(url, data=body, method="POST", headers={"User-Agent": UA, **headers})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)


def dishtv_token():
    return post(SIGNIN, {"X-Requested-With": "XMLHttpRequest",
                         "Referer": "https://www.dishtv.in/channel-guide.html"})["token"]


def english(item, key):
    regional = item.get("regional") or {}
    for lang in ["english"] + sorted(regional):
        value = (regional.get(lang) or {}).get(key)
        if value:
            return value.strip()
    return ""


def ist(stamp):
    # The guide's times are India local time, although they carry a "Z".
    return dt.datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=IST)


def dishtv_programmes(token, site_id, days):
    seen, out = set(), []
    for day in days:
        items = post(PROGRAMS, {"Authorization": token, "Content-Type": "application/json"},
                     json.dumps({"allowPastEvents": True, "channelid": site_id,
                                 "date": day.strftime("%d/%m/%Y")}).encode())
        for item in items if isinstance(items, list) else []:
            start, stop = ist(item["start"]), ist(item["stop"])
            if start in seen or stop <= start:
                continue
            seen.add(start)
            out.append({"start": start, "stop": stop, "title": english(item, "title") or "Live",
                        "desc": english(item, "desc"), "category": english(item, "genre")})
    return sorted(out, key=lambda p: p["start"])


def placeholder(name, days):
    return [{"start": dt.datetime.combine(d, dt.time(), IST),
             "stop": dt.datetime.combine(d + dt.timedelta(days=1), dt.time(), IST),
             "title": f"{name} Live", "desc": "", "category": ""} for d in days]


def fmt(t):
    return t.strftime("%Y%m%d%H%M%S %z")


def main():
    channels = json.loads(os.environ["IPTV_EPG_CHANNELS"])
    today = dt.datetime.now(IST).date()
    days = [today + dt.timedelta(days=i) for i in range(DAYS)]
    token = None
    if any(c.get("dishtv") for c in channels):
        try:
            token = dishtv_token()
        except Exception as e:  # noqa: BLE001 - any failure means placeholders
            print(f"epg: Dish TV sign-in failed: {e}", file=sys.stderr)

    tv = ET.Element("tv", {"generator-info-name": "anvil iptv-epg"})
    programmes = []
    for c in channels:
        ch = ET.SubElement(tv, "channel", {"id": c["id"]})
        ET.SubElement(ch, "display-name").text = c["name"]
        progs, source = [], "placeholder"
        if c.get("dishtv") and token:
            try:
                progs, source = dishtv_programmes(token, c["dishtv"], days), "dishtv"
            except Exception as e:  # noqa: BLE001
                print(f"epg: {c['id']}: Dish TV guide failed: {e}", file=sys.stderr)
        if not progs:
            progs, source = placeholder(c["name"], days), "placeholder"
        print(f"epg: {c['id']}: {source}, {len(progs)} programmes", file=sys.stderr)
        programmes += [(c["id"], p) for p in progs]

    for cid, p in programmes:
        el = ET.SubElement(tv, "programme", {"start": fmt(p["start"]), "stop": fmt(p["stop"]), "channel": cid})
        ET.SubElement(el, "title", {"lang": "en"}).text = p["title"]
        if p["desc"]:
            ET.SubElement(el, "desc", {"lang": "en"}).text = p["desc"]
        if p["category"]:
            ET.SubElement(el, "category", {"lang": "en"}).text = p["category"]

    ET.indent(tv)
    sys.stdout.write('<?xml version="1.0" encoding="UTF-8"?>\n')
    sys.stdout.write(ET.tostring(tv, encoding="unicode"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
