#!/usr/bin/env python3
"""arr-indexers.py: Prowlarr's indexers, as code (role arr_stack, tag arr_indexers).

Usage: arr-indexers.py [--check] <policy as JSON>

The policy: {"url": "http://...", "config_xml": "<path>",
             "indexers": [{"definition": "Knaben", "tags": ["cloudflare"]},
                          {"definition": "nyaasi", "base_url": "https://nyaa.land/"}, ...],
             "apps": {"radarr": {"url": "http://...", "config_xml": "<path>",
                                 "off": ["RARBG", ...]}}}

Each indexer is a Prowlarr definition (definitionName, as in Prowlarr's schema). One that
is missing is added from the schema, on base_url or else its first site address, in the
first app profile, with the given tags (a tag is created when missing; "cloudflare" routes
it through the FlareSolverr proxy). One that is there but switched off is switched on, and
one on another address than base_url is moved to it (for a site the line blocks: one of
its mirrors). Prowlarr tests an indexer before it saves it: a site that is down is
reported and skipped, and the run goes on. Indexers that are not in the policy, added in
the web UI, are never touched. Prowlarr syncs the indexers to Sonarr and Radarr itself.

apps.<app>.off names indexers added by hand in Sonarr or Radarr, not synced by Prowlarr:
they are switched off (RSS, automatic and interactive search), never deleted, so the web
UI can switch one back on.

The API key is read from config.xml on this host, sent only as a header, and never printed.
--check prints what would change and changes nothing.
"""
import json
import re
import sys
import urllib.error
import urllib.request


def api_key(path):
    m = re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", open(path, encoding="utf-8").read())
    if not m:
        raise SystemExit(f"arr-indexers: no API key in {path}")
    return m.group(1)


class Api:
    def __init__(self, name, url, key, version="v1"):
        self.name, self.url, self.key, self.version = name, url.rstrip("/"), key, version

    def call(self, method, path, body=None):
        """The decoded answer, or (code, text) for an HTTP error the caller handles."""
        req = urllib.request.Request(f"{self.url}/api/{self.version}{path}", method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"X-Api-Key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors="replace")
        except (urllib.error.URLError, OSError) as e:
            raise SystemExit(f"arr-indexers: {self.name}: {method} {path}: {getattr(e, 'reason', e)}") from None
        return json.loads(text) if text.strip() else None

    def get(self, path):
        r = self.call("GET", path)
        if isinstance(r, tuple):
            raise SystemExit(f"arr-indexers: {self.name}: GET {path}: HTTP {r[0]}")
        return r


def reason(text):
    """Prowlarr's validation message, short: why a site failed its test."""
    try:
        errs = json.loads(text)
        msgs = [e.get("errorMessage", "") for e in errs] if isinstance(errs, list) else [str(errs)]
    except ValueError:
        msgs = [text]
    return " ".join(m for m in msgs if m)[:160] or "no reason given"


def new_indexer(schema, want, tag_ids, profile_id):
    ix = json.loads(json.dumps(schema))
    ix.pop("id", None)
    ix["enable"] = True
    ix["appProfileId"] = profile_id
    ix["tags"] = tag_ids
    ix.setdefault("priority", 25)
    for f in ix.get("fields", []):
        if f.get("name") == "baseUrl":
            if want.get("base_url"):
                f["value"] = want["base_url"]
            elif not f.get("value") and ix.get("indexerUrls"):
                f["value"] = ix["indexerUrls"][0]
    return ix


def base_url(ix):
    """An indexer's site address: its baseUrl field, else its first site address."""
    for f in ix.get("fields", []):
        if f.get("name") == "baseUrl" and f.get("value"):
            return f["value"]
    return (ix.get("indexerUrls") or [""])[0]


def switch_off(app, a, check):
    """Switch off the hand-added indexers apps.<app>.off names. Returns the failures."""
    api = Api(app, a["url"], api_key(a["config_xml"]), "v3")
    failed = 0
    for ix in api.get("/indexer"):
        if ix["name"] not in a.get("off", []):
            continue
        if not (ix.get("enableRss") or ix.get("enableAutomaticSearch") or ix.get("enableInteractiveSearch")):
            print(f"{app}: {ix['name']}: off")
            continue
        if check:
            print(f"{app}: {ix['name']}: would switch off")
            continue
        ix.update(enableRss=False, enableAutomaticSearch=False, enableInteractiveSearch=False)
        # forceSave: the app tests an indexer on save, and one switched off for failing
        # would fail that test.
        r = api.call("PUT", f"/indexer/{ix['id']}?forceSave=true", ix)
        if isinstance(r, tuple):
            print(f"{app}: {ix['name']}: cannot switch off (HTTP {r[0]}): {reason(r[1])}")
            failed += 1
        else:
            print(f"{app}: {ix['name']}: do: switched off")
    return failed


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    policy = json.loads(args[0])
    p = Api("prowlarr", policy["url"], api_key(policy["config_xml"]))

    have = {i["definitionName"].lower(): i for i in p.get("/indexer")}
    schemas = {s["definitionName"].lower(): s for s in p.get("/indexer/schema") if s.get("definitionName")}
    tags = {t["label"]: t["id"] for t in p.get("/tag")}
    profiles = p.get("/appprofile")
    if not profiles:
        raise SystemExit("arr-indexers: prowlarr has no app profile")
    failed = 0

    for want in policy["indexers"]:
        d = want["definition"]
        cur = have.get(d.lower())
        if cur:
            todo = []
            if not cur["enable"]:
                todo.append("switch on")
            if want.get("base_url") and base_url(cur).rstrip("/") != want["base_url"].rstrip("/"):
                todo.append(f"move to {want['base_url']}")
            if not todo:
                print(f"prowlarr: {cur['name']}: ok")
                continue
            if check:
                print(f"prowlarr: {cur['name']}: would {' and '.join(todo)}")
                continue
            cur["enable"] = True
            if want.get("base_url"):
                for f in cur.get("fields", []):
                    if f.get("name") == "baseUrl":
                        f["value"] = want["base_url"]
            r = p.call("PUT", f"/indexer/{cur['id']}", cur)
            if isinstance(r, tuple):
                print(f"prowlarr: {cur['name']}: cannot {' and '.join(todo)} (HTTP {r[0]}): {reason(r[1])}")
                failed += 1
            else:
                done = [t.replace("switch on", "switched on").replace("move to", "moved to") for t in todo]
                print(f"prowlarr: {cur['name']}: do: {' and '.join(done)}")
            continue
        schema = schemas.get(d.lower())
        if not schema:
            print(f"prowlarr: {d}: no such definition in this Prowlarr")
            failed += 1
            continue
        missing_tags = [t for t in want.get("tags", []) if t not in tags]
        if check:
            print(f"prowlarr: {schema['name']}: would add" + (f" (and tags {', '.join(missing_tags)})" if missing_tags else ""))
            continue
        for t in missing_tags:
            r = p.call("POST", "/tag", {"label": t})
            if isinstance(r, tuple):
                raise SystemExit(f"arr-indexers: prowlarr: cannot create tag {t}: HTTP {r[0]}")
            tags[t] = r["id"]
            print(f"prowlarr: tag {t}: do: created")
        ix = new_indexer(schema, want, [tags[t] for t in want.get("tags", [])], profiles[0]["id"])
        r = p.call("POST", "/indexer", ix)
        if isinstance(r, tuple):
            print(f"prowlarr: {schema['name']}: skipped, its test failed (HTTP {r[0]}): {reason(r[1])}")
            failed += 1
        else:
            print(f"prowlarr: {schema['name']}: do: added")
    for app, a in policy.get("apps", {}).items():
        failed += switch_off(app, a, check)
    if failed:
        print(f"arr-indexers: {failed} indexer(s) not ready, the others are")


if __name__ == "__main__":
    main(sys.argv[1:])
