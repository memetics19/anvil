#!/usr/bin/env python3
"""arr-quality.py: the quality policy of Sonarr and Radarr, as code (role arr_stack, tag
arr_quality).

Usage: arr-quality.py [--check] <policy as JSON>

The policy: {"apps": {"<app>": {"url": "http://...", "config_xml": "<path>"}},
             "profile": "<name>", "min_resolution": 1080, "exclude": ["remux", ...],
             "min_sizes": {"WEBDL-2160p": 10, ...}}

For each app:
  - the quality profile <profile> allows every quality of at least min_resolution whose
    name holds none of the exclude words, and nothing else. Its cutoff is the lowest
    allowed quality of exactly min_resolution, so a release at that resolution is final.
    It is created when missing and corrected when it differs. Other profiles and the
    series or movies are never touched.
  - the quality definitions in min_sizes get that minimum size (MB per minute).
Each app's API key is read from its config.xml on this host, sent only as a header, and
never printed. --check prints what would change and changes nothing.
"""
import json
import re
import sys
import urllib.error
import urllib.request


def api_key(path):
    m = re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", open(path, encoding="utf-8").read())
    if not m:
        raise SystemExit(f"arr-quality: no API key in {path}")
    return m.group(1)


class App:
    def __init__(self, name, url, key):
        self.name, self.url, self.key = name, url.rstrip("/"), key

    def call(self, method, path, body=None):
        req = urllib.request.Request(f"{self.url}/api/v3{path}", method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"X-Api-Key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:
            raise SystemExit(f"arr-quality: {self.name}: {method} {path}: HTTP {e.code}") from None
        except (urllib.error.URLError, OSError) as e:
            raise SystemExit(f"arr-quality: {self.name}: {method} {path}: {getattr(e, 'reason', e)}") from None
        return json.loads(text) if text.strip() else None


def qualities(item):
    """The qualities in a profile item: one, or a group's members."""
    return [item["quality"]] if item.get("quality") else [i["quality"] for i in item.get("items", [])]


def item_name(item):
    return item["quality"]["name"] if item.get("quality") else item["name"]


def wanted(item, min_res, exclude):
    qs = qualities(item)
    return bool(qs) and all(
        (q.get("resolution") or 0) >= min_res and not any(w in q["name"].lower() for w in exclude) for q in qs)


def item_id(item):
    return item["quality"]["id"] if item.get("quality") else item["id"]


def desired_profile(schema, name, min_res, exclude):
    p = json.loads(json.dumps(schema))
    cutoff = None
    # The schema lists items from the lowest quality to the highest.
    for it in p["items"]:
        it["allowed"] = wanted(it, min_res, exclude)
        for sub in it.get("items", []):
            sub["allowed"] = it["allowed"]
        if it["allowed"] and cutoff is None and all((q.get("resolution") or 0) == min_res for q in qualities(it)):
            cutoff = item_id(it)
    if cutoff is None:
        raise SystemExit(f"arr-quality: no quality of exactly {min_res}p is allowed, so there is no cutoff")
    p.update(name=name, upgradeAllowed=True, cutoff=cutoff)
    return p


def allowed_names(p):
    return sorted(item_name(i) for i in p["items"] if i.get("allowed"))


def main(args):
    check = False
    if args and args[0] == "--check":
        check, args = True, args[1:]
    if len(args) != 1:
        raise SystemExit(__doc__)
    pol = json.loads(args[0])
    name, min_res = pol["profile"], int(pol["min_resolution"])
    exclude = [w.lower() for w in pol.get("exclude", [])]
    word = "would" if check else "do:"
    changes = 0
    for app_name, a in sorted(pol["apps"].items()):
        app = App(app_name, a["url"], api_key(a["config_xml"]))
        want = desired_profile(app.call("GET", "/qualityprofile/schema"), name, min_res, exclude)
        have = next((p for p in app.call("GET", "/qualityprofile") if p["name"] == name), None)
        if have is None:
            print(f"{app_name}: {word} create profile {name}: {', '.join(allowed_names(want))}")
            changes += 1
            if not check:
                app.call("POST", "/qualityprofile", want)
        elif (allowed_names(have) != allowed_names(want) or have.get("cutoff") != want["cutoff"]
              or not have.get("upgradeAllowed")):
            print(f"{app_name}: {word} correct profile {name}: {', '.join(allowed_names(want))}")
            changes += 1
            if not check:
                want["id"] = have["id"]
                app.call("PUT", f"/qualityprofile/{have['id']}", want)
        else:
            print(f"{app_name}: ok: profile {name}")
        for d in app.call("GET", "/qualitydefinition"):
            size = pol.get("min_sizes", {}).get(d["quality"]["name"])
            if size is not None and d["minSize"] != size:
                print(f"{app_name}: {word} set {d['quality']['name']} minimum to {size} MB/min (was {d['minSize']})")
                changes += 1
                if not check:
                    d["minSize"] = size
                    app.call("PUT", f"/qualitydefinition/{d['id']}", d)
    print(f"arr-quality: {changes} change(s)" + (" (check only)" if check else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
