#!/usr/bin/env python3
"""arr-indexers.py: Prowlarr's indexers, as code (role arr_stack, tag arr_indexers).

Usage: arr-indexers.py [--check] <policy as JSON>

The policy: {"url": "http://...", "config_xml": "<path>",
             "indexers": [{"definition": "Knaben", "tags": ["cloudflare"]}, ...]}

Each indexer is a Prowlarr definition (definitionName, as in Prowlarr's schema). One that
is missing is added from the schema, on its first site address, in the first app profile,
with the given tags (a tag is created when missing; "cloudflare" routes it through the
FlareSolverr proxy). One that is there but switched off is switched on. Prowlarr tests an
indexer before it saves it: a site that is down is reported and skipped, and the run goes
on. Indexers that are not in the policy, added in the web UI, are never touched. Prowlarr
syncs the indexers to Sonarr and Radarr itself.

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


class Prowlarr:
    def __init__(self, url, key):
        self.url, self.key = url.rstrip("/"), key

    def call(self, method, path, body=None):
        """The decoded answer, or (code, text) for an HTTP error the caller handles."""
        req = urllib.request.Request(f"{self.url}/api/v1{path}", method=method,
                                     data=None if body is None else json.dumps(body).encode(),
                                     headers={"X-Api-Key": self.key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                text = r.read().decode()
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode(errors="replace")
        except (urllib.error.URLError, OSError) as e:
            raise SystemExit(f"arr-indexers: prowlarr: {method} {path}: {getattr(e, 'reason', e)}") from None
        return json.loads(text) if text.strip() else None

    def get(self, path):
        r = self.call("GET", path)
        if isinstance(r, tuple):
            raise SystemExit(f"arr-indexers: prowlarr: GET {path}: HTTP {r[0]}")
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
        if f.get("name") == "baseUrl" and not f.get("value") and ix.get("indexerUrls"):
            f["value"] = ix["indexerUrls"][0]
    return ix


def main(argv):
    check = "--check" in argv
    args = [a for a in argv if a != "--check"]
    if len(args) != 1:
        raise SystemExit(__doc__)
    policy = json.loads(args[0])
    p = Prowlarr(policy["url"], api_key(policy["config_xml"]))

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
        if cur and cur["enable"]:
            print(f"prowlarr: {cur['name']}: ok")
            continue
        if cur:
            if check:
                print(f"prowlarr: {cur['name']}: would switch on")
                continue
            cur["enable"] = True
            r = p.call("PUT", f"/indexer/{cur['id']}", cur)
            if isinstance(r, tuple):
                print(f"prowlarr: {cur['name']}: cannot switch on (HTTP {r[0]}): {reason(r[1])}")
                failed += 1
            else:
                print(f"prowlarr: {cur['name']}: do: switched on")
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
    if failed:
        print(f"prowlarr: {failed} indexer(s) not ready, the others are")


if __name__ == "__main__":
    main(sys.argv[1:])
