#!/usr/bin/env python3
"""arr-bazarr.py: Bazarr, the subtitles, as code (role arr_stack, tag arr_subtitles).

Usage: arr-bazarr.py [--check] <policy as JSON> < <account as JSON>

The policy: {"url": "http://...:6767", "config_yaml": "<path>",
             "sonarr": {"host": "sonarr", "port": 8989, "url": "http://...", "config_xml": "<path>"},
             "radarr": {...same...},
             "languages": ["en"], "profile": "English"}
The account, on stdin (never on the command line): {"opensubtitles_username": "...",
"opensubtitles_password": "..."}, or {} for none.

Bazarr:
  - is connected to Sonarr and Radarr, on their compose names, with their API keys
  - has the policy's languages switched on, and one language profile named after the
    policy with those languages (created when missing, corrected when it differs)
  - gives that profile to new series and movies, and to every one that has none
  - counts subtitles already inside a file (use_embedded_subs)
  - downloads from OpenSubtitles.com with the account, when there is one. Other providers
    switched on in the web UI are kept.
Sonarr and Radarr import the .srt files a release ships with (importExtraFiles, srt).

Only what differs is changed. Each API key is read from its app's file on this host, sent
only as a header, and never printed, nor is the account. --check prints what would change
and changes nothing.
"""
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def fail(msg):
    raise SystemExit(f"arr-bazarr: {msg}")


def xml_key(path):
    m = re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", open(path, encoding="utf-8").read())
    if not m:
        fail(f"no API key in {path}")
    return m.group(1)


def auth_apikey(text):
    """The apikey in the auth section of Bazarr's config.yaml, read line by line."""
    in_auth = False
    for line in text.splitlines():
        if line and not line[0].isspace():
            in_auth = line.rstrip() == "auth:"
            continue
        if in_auth:
            key, _, value = line.strip().partition(":")
            value = value.strip().strip("'\"")
            if key == "apikey" and re.fullmatch(r"[0-9a-f]{32}", value):
                return value
    return None


def bazarr_key(path, wait=90):
    """Bazarr writes its key into config.yaml (auth: apikey:) on its first start."""
    deadline = time.time() + wait
    while True:
        try:
            key = auth_apikey(open(path, encoding="utf-8").read())
            if key:
                return key
        except FileNotFoundError:
            pass
        if time.time() > deadline:
            fail(f"no API key in {path} (has Bazarr started?)")
        time.sleep(3)


class Api:
    def __init__(self, name, url, key, prefix):
        self.name, self.url, self.key, self.prefix = name, url.rstrip("/"), key, prefix

    def call(self, method, path, body=None, form=None):
        data, ctype = None, "application/json"
        if form is not None:
            data, ctype = urllib.parse.urlencode(form, doseq=True).encode(), "application/x-www-form-urlencoded"
        elif body is not None:
            data = json.dumps(body).encode()
        req = urllib.request.Request(f"{self.url}{self.prefix}{path}", method=method, data=data,
                                     headers={"X-Api-Key": self.key, "X-API-KEY": self.key, "Content-Type": ctype})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:
            fail(f"{self.name}: {method} {path.split('?')[0]}: HTTP {e.code}")
        except (urllib.error.URLError, OSError) as e:
            fail(f"{self.name}: {method} {path.split('?')[0]}: {getattr(e, 'reason', e)}")
        return json.loads(text) if text.strip() else None


def wait_ready(api, wait=120):
    deadline = time.time() + wait
    while True:
        try:
            return api.call("GET", "/system/settings")
        except SystemExit:
            if time.time() > deadline:
                raise
            time.sleep(3)


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    policy = json.loads(args[0])
    account = json.loads(sys.stdin.read() or "{}")
    user = account.get("opensubtitles_username") or ""
    secret = account.get("opensubtitles_password") or ""

    if check:
        try:
            open(policy["config_yaml"], encoding="utf-8").close()
        except FileNotFoundError:
            print("bazarr: not started yet: would be set up after its first start")
            return
    b = Api("bazarr", policy["url"], bazarr_key(policy["config_yaml"]), "/api")
    cur = wait_ready(b)
    form = {}

    def want(section, key, value, label=None):
        have = cur.get(section, {}).get(key)
        if isinstance(value, bool):
            same = have is value
        elif isinstance(value, list):
            same = sorted(have or []) == sorted(value)
        else:
            same = str(have) == str(value)
        if not same:
            form[f"settings-{section}-{key}"] = (["true" if value else "false"] if isinstance(value, bool)
                                                 else value if isinstance(value, list) else [str(value)])
            print(f"bazarr: {label or section + '.' + key}: {'would set' if check else 'do: set'}")

    for app in ("sonarr", "radarr"):
        a = policy[app]
        want("general", f"use_{app}", True)
        want(app, "ip", a["host"])
        want(app, "port", a["port"])
        want(app, "ssl", False)
        want(app, "base_url", "/")
        want(app, "apikey", xml_key(a["config_xml"]), f"{app}.apikey")
    want("general", "use_embedded_subs", True)
    if user and secret:
        want("opensubtitlescom", "username", user, "opensubtitlescom.username")
        want("opensubtitlescom", "password", secret, "opensubtitlescom.password")
        providers = sorted(set(cur.get("general", {}).get("enabled_providers") or []) | {"opensubtitlescom"})
        want("general", "enabled_providers", providers)
    else:
        print("bazarr: no OpenSubtitles.com account in Vault: set up, but it downloads nothing yet")

    # Languages and the profile, in Bazarr's database (the same form post).
    langs = policy["languages"]
    enabled = sorted(x["code2"] for x in b.call("GET", "/system/languages") if x.get("enabled"))
    if not set(langs) <= set(enabled):
        form["languages-enabled"] = sorted(set(enabled) | set(langs))
        print(f"bazarr: languages {', '.join(langs)}: {'would switch on' if check else 'do: switch on'}")
    profiles = b.call("GET", "/system/languages/profiles") or []
    mine = next((p for p in profiles if p["name"] == policy["profile"]), None)
    items = [{"id": i + 1, "language": code, "audio_exclude": "False", "audio_only_include": "False",
              "hi": "False", "forced": "False"} for i, code in enumerate(langs)]
    if mine is None or [i["language"] for i in mine.get("items", [])] != langs:
        pid = mine["profileId"] if mine else max([p["profileId"] for p in profiles] or [0]) + 1
        new = {"profileId": pid, "name": policy["profile"], "cutoff": None, "items": items,
               "mustContain": [], "mustNotContain": [], "originalFormat": None}
        others = [p for p in profiles if p["profileId"] != pid]
        form["languages-profiles"] = [json.dumps(others + [new])]
        print(f"bazarr: profile {policy['profile']}: {'would ' if check else 'do: '}{'create' if mine is None else 'correct'}")
    else:
        pid = mine["profileId"]
    want("general", "serie_default_enabled", True)
    want("general", "serie_default_profile", pid)
    want("general", "movie_default_enabled", True)
    want("general", "movie_default_profile", pid)

    if form and not check:
        b.call("POST", "/system/settings", form=form)

    # Every series and movie without a profile gets the policy's.
    for kind, idkey, field in (("series", "sonarrSeriesId", "seriesid"), ("movies", "radarrId", "radarrid")):
        rows = (b.call("GET", f"/{kind}?start=0&length=-1") or {}).get("data", [])
        none = [r[idkey] for r in rows if r.get("profileId") in (None, "", 0)]
        if not none:
            print(f"bazarr: {kind}: every one has a profile")
            continue
        print(f"bazarr: {kind}: {len(none)} without a profile: {'would give' if check else 'do: gave'} them {policy['profile']}")
        if not check:
            b.call("POST", f"/{kind}", form={field: none, "profileid": [str(pid)] * len(none)})

    # Sonarr and Radarr keep the .srt files a release ships with.
    for app in ("sonarr", "radarr"):
        a = policy[app]
        api = Api(app, a["url"], xml_key(a["config_xml"]), "/api/v3")
        mm = api.call("GET", "/config/mediamanagement")
        exts = {e.strip().lstrip(".") for e in (mm.get("extraFileExtensions") or "").split(",") if e.strip()}
        if mm.get("importExtraFiles") and "srt" in exts:
            print(f"{app}: imports .srt files: ok")
            continue
        print(f"{app}: import .srt files: {'would switch on' if check else 'do: switch on'}")
        if not check:
            mm["importExtraFiles"] = True
            mm["extraFileExtensions"] = ",".join(sorted(exts | {"srt"}))
            api.call("PUT", f"/config/mediamanagement/{mm['id']}", mm)


if __name__ == "__main__":
    main(sys.argv[1:])
