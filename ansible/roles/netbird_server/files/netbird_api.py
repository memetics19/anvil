#!/usr/bin/env python3
"""NetBird management API helper for the self-hosted server (role netbird_server).

Reads one JSON request on stdin (never argv: it holds the API token and passwords) and
prints one JSON result on stdout. Standard library only, so it runs on the VM as is.

Request: {"api": "http://127.0.0.1:8089/api", "action": ..., "check": bool, ...}

Actions
  status     -> {"setup_required": bool}
  setup      first owner user and a personal access token (only while setup is required);
             request: email, password, name, pat_days -> {"changed": [...], "secrets": {"api_token"}}
  reconcile  apply the desired state; request: token, desired (see the role defaults) and
             pat_days / pat_renew_days. Objects are matched by name. Only the named
             objects and fields are managed; anything else in the account is left alone,
             except the policies listed in desired.delete_policies.
             -> {"changed": [...], "warnings": [...], "secrets": {"api_token"?}}
  setup_key  a new one-off setup key; request: token, name, auto_groups, expires_in.
             Older keys with that name are revoked. -> {"changed": [...], "secrets": {"setup_key"}}

Output lists only object names (no addresses, no secrets) except the "secrets" dict,
which the caller stores in Vault without displaying it.
"""
import json
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone


class ApiError(Exception):
    pass


class Api:
    def __init__(self, base, token=None, check=False):
        self.base = base.rstrip("/")
        self.token = token
        self.check = check
        self.changed = []

    def call(self, method, path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", "Token " + self.token)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
        except urllib.error.HTTPError as e:
            msg = e.read()[:300].decode(errors="replace")
            raise ApiError(f"{method} {path}: HTTP {e.code}: {msg}") from None
        except urllib.error.URLError as e:
            raise ApiError(f"{method} {path}: {e.reason}") from None
        return json.loads(raw) if raw.strip() else None

    def get(self, path):
        return self.call("GET", path)

    def write(self, method, path, body, what):
        """A change: recorded always, sent only outside check mode."""
        self.changed.append(what)
        if self.check:
            return None
        return self.call(method, path, body)


def by_name(items):
    return {i.get("name"): i for i in items or []}


def group_ids(api, names, groups):
    ids = []
    for n in names:
        g = groups.get(n)
        if g is None:
            if api.check:
                ids.append("new:" + n)
                continue
            raise ApiError(f"group {n} does not exist")
        ids.append(g["id"])
    return sorted(ids)


def ensure_groups(api, names):
    groups = by_name(api.get("/groups"))
    for n in names:
        if n not in groups:
            g = api.write("POST", "/groups", {"name": n}, f"group {n}: create")
            if g:
                groups[n] = g
    return groups


def ensure_settings(api, desired):
    accounts = api.get("/accounts")
    if not accounts:
        raise ApiError("no account")
    acc = accounts[0]
    settings = dict(acc.get("settings") or {})
    diff = [k for k, v in desired.items() if settings.get(k) != v]
    if diff:
        settings.update(desired)
        api.write("PUT", f"/accounts/{acc['id']}", {"settings": settings},
                  "account settings: " + ", ".join(sorted(diff)))


def ensure_owner_groups(api, email, auto_groups, groups):
    users = api.get("/users") or []
    user = next((u for u in users if (u.get("email") or "").lower() == email.lower()), None)
    if user is None:
        raise ApiError("the owner user is missing")
    want = group_ids(api, auto_groups, groups)
    have = sorted(user.get("auto_groups") or [])
    if have != want:
        body = {"role": user.get("role", "owner"), "auto_groups": want,
                "is_blocked": bool(user.get("is_blocked", False))}
        api.write("PUT", f"/users/{user['id']}", body, "owner user: auto groups")


def rule_ids(rule, key):
    out = []
    for g in rule.get(key) or []:
        out.append(g["id"] if isinstance(g, dict) else g)
    return sorted(out)


def ensure_policies(api, policies, delete_names, groups):
    have = by_name(api.get("/policies"))
    for p in policies:
        rule = {
            "name": p["name"],
            "description": p.get("description", ""),
            "enabled": True,
            "action": "accept",
            "bidirectional": False,
            "protocol": "all",
            "sources": group_ids(api, p["sources"], groups),
            "destinations": group_ids(api, p["destinations"], groups),
        }
        body = {"name": p["name"], "description": p.get("description", ""), "enabled": True,
                "rules": [rule], "source_posture_checks": []}
        cur = have.get(p["name"])
        if cur is None:
            api.write("POST", "/policies", body, f"policy {p['name']}: create")
            continue
        rules = cur.get("rules") or []
        same = (cur.get("enabled") and len(rules) == 1
                and rules[0].get("enabled") and rules[0].get("action") == "accept"
                and not rules[0].get("bidirectional") and rules[0].get("protocol") == "all"
                and rule_ids(rules[0], "sources") == rule["sources"]
                and rule_ids(rules[0], "destinations") == rule["destinations"]
                and not rules[0].get("ports") and not rules[0].get("port_ranges")
                and not rules[0].get("sourceResource") and not rules[0].get("destinationResource")
                and (cur.get("description") or "") == body["description"])
        if not same:
            if rules and rules[0].get("id"):
                rule["id"] = rules[0]["id"]
            api.write("PUT", f"/policies/{cur['id']}", body, f"policy {p['name']}: update")
    for n in delete_names:
        if n in have:
            api.write("DELETE", f"/policies/{have[n]['id']}", None, f"policy {n}: delete")


def ensure_networks(api, networks, groups):
    have = by_name(api.get("/networks"))
    for n in networks:
        cur = have.get(n["name"])
        if cur is None:
            cur = api.write("POST", "/networks",
                            {"name": n["name"], "description": n.get("description", "")},
                            f"network {n['name']}: create")
            if cur is None:  # check mode: everything below would be created
                for r in n["resources"]:
                    api.changed.append(f"network {n['name']}: resource {r['name']}: create")
                for _ in n["routers"]:
                    api.changed.append(f"network {n['name']}: router: create")
                continue
        elif (cur.get("description") or "") != n.get("description", ""):
            api.write("PUT", f"/networks/{cur['id']}",
                      {"name": n["name"], "description": n.get("description", "")},
                      f"network {n['name']}: update")
        base = f"/networks/{cur['id']}"
        res = by_name(api.get(base + "/resources"))
        for r in n["resources"]:
            body = {"name": r["name"], "description": r.get("description", ""),
                    "address": r["address"], "enabled": True,
                    "groups": group_ids(api, r["groups"], groups)}
            c = res.get(r["name"])
            if c is None:
                api.write("POST", base + "/resources", body,
                          f"network {n['name']}: resource {r['name']}: create")
                continue
            cgroups = sorted(g["id"] if isinstance(g, dict) else g for g in c.get("groups") or [])
            if (c.get("address") != r["address"] or not c.get("enabled")
                    or cgroups != body["groups"]):
                api.write("PUT", f"{base}/resources/{c['id']}", body,
                          f"network {n['name']}: resource {r['name']}: update")
        routers = api.get(base + "/routers") or []
        for i, r in enumerate(n["routers"]):
            body = {"peer_groups": group_ids(api, r["peer_groups"], groups),
                    "masquerade": bool(r["masquerade"]), "metric": int(r["metric"]),
                    "enabled": True}
            match = next((x for x in routers
                          if sorted(x.get("peer_groups") or []) == body["peer_groups"]), None)
            if match is None and i < len(routers) and len(routers) == len(n["routers"]):
                match = routers[i]
            if match is None:
                api.write("POST", base + "/routers", body, f"network {n['name']}: router: create")
                continue
            same = (sorted(match.get("peer_groups") or []) == body["peer_groups"]
                    and not match.get("peer")
                    and bool(match.get("masquerade")) == body["masquerade"]
                    and int(match.get("metric", 0)) == body["metric"]
                    and match.get("enabled"))
            if not same:
                api.write("PUT", f"{base}/routers/{match['id']}", body,
                          f"network {n['name']}: router: update")


def ensure_nameservers(api, nameservers, groups):
    have = by_name(api.get("/dns/nameservers"))
    for ns in nameservers:
        body = {"name": ns["name"], "description": ns.get("description", ""),
                "nameservers": [{"ip": s["ip"], "ns_type": s.get("ns_type", "udp"),
                                 "port": int(s.get("port", 53))} for s in ns["nameservers"]],
                "enabled": True, "groups": group_ids(api, ns["groups"], groups),
                "primary": False, "domains": sorted(ns["domains"]),
                "search_domains_enabled": False}
        cur = have.get(ns["name"])
        if cur is None:
            api.write("POST", "/dns/nameservers", body, f"nameserver group {ns['name']}: create")
            continue
        cur_ns = [{"ip": s.get("ip"), "ns_type": s.get("ns_type"), "port": int(s.get("port", 53))}
                  for s in cur.get("nameservers") or []]
        same = (cur_ns == body["nameservers"] and cur.get("enabled")
                and sorted(cur.get("groups") or []) == body["groups"]
                and not cur.get("primary") and sorted(cur.get("domains") or []) == body["domains"]
                and not cur.get("search_domains_enabled")
                and (cur.get("description") or "") == body["description"])
        if not same:
            api.write("PUT", f"/dns/nameservers/{cur['id']}", body,
                      f"nameserver group {ns['name']}: update")


def all_to_all(api):
    """Names of enabled policies with a rule from group All to group All."""
    out = []
    groups = {g["id"]: g.get("name") for g in api.get("/groups") or []}
    for p in api.get("/policies") or []:
        if not p.get("enabled"):
            continue
        for r in p.get("rules") or []:
            src = [groups.get(i) for i in rule_ids(r, "sources")]
            dst = [groups.get(i) for i in rule_ids(r, "destinations")]
            if r.get("enabled") and "All" in src and "All" in dst:
                out.append(p.get("name"))
                break
    return out


def parse_time(s):
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    if "." in s:  # trim sub-second digits Python 3.10 cannot parse
        head, rest = s.split(".", 1)
        tz = rest[next((i for i, c in enumerate(rest) if c in "+-"), len(rest)):]
        s = head + tz
    return datetime.fromisoformat(s)


def renew_token(api, days, renew_days):
    """A new personal access token when the owner's newest one has fewer than renew_days
    left (the role stores each new token in Vault, so the newest is the one in use)."""
    me = api.get("/users/current")
    tokens = api.get(f"/users/{me['id']}/tokens") or []
    now = datetime.now(timezone.utc)
    left = [(parse_time(t.get("expiration_date")) - now).days
            for t in tokens if t.get("expiration_date")]
    if left and max(left) >= renew_days:
        return None
    new = api.write("POST", f"/users/{me['id']}/tokens", {"name": "anvil", "expires_in": days},
                    "owner user: new personal access token")
    return (new or {}).get("plain_token")


def main():
    req = json.load(sys.stdin)
    api = Api(req["api"], req.get("token"), bool(req.get("check")))
    out = {"changed": api.changed, "warnings": [], "secrets": {}}
    action = req["action"]
    if action == "status":
        out["setup_required"] = bool(api.get("/instance").get("setup_required"))
    elif action == "setup":
        if not api.get("/instance").get("setup_required"):
            raise ApiError("setup is not required: the owner exists")
        res = api.write("POST", "/setup", {
            "email": req["email"], "password": req["password"], "name": req["name"],
            "create_pat": True, "pat_expire_in": int(req["pat_days"])}, "owner user: create")
        if res is not None:
            if not res.get("personal_access_token"):
                raise ApiError("setup returned no personal access token")
            out["secrets"]["api_token"] = res["personal_access_token"]
    elif action == "reconcile":
        d = req["desired"]
        ensure_settings(api, d.get("settings", {}))
        groups = ensure_groups(api, d["groups"])
        ensure_owner_groups(api, d["owner_email"], d["owner_auto_groups"], groups)
        ensure_policies(api, d["policies"], d.get("delete_policies", []), groups)
        ensure_networks(api, d["networks"], groups)
        ensure_nameservers(api, d["nameservers"], groups)
        if not api.check:
            left = all_to_all(api)
            if left:
                out["warnings"].append("All to All policies remain: " + ", ".join(left))
        tok = renew_token(api, int(req["pat_days"]), int(req["pat_renew_days"]))
        if tok:
            out["secrets"]["api_token"] = tok
    elif action == "setup_key":
        groups = by_name(api.get("/groups"))
        ids = group_ids(api, req["auto_groups"], groups)
        for k in api.get("/setup-keys") or []:
            if k.get("name") == req["name"] and not k.get("revoked"):
                api.write("PUT", f"/setup-keys/{k['id']}",
                          {"revoked": True, "auto_groups": k.get("auto_groups") or []},
                          f"setup key {req['name']}: revoke an older one")
        new = api.write("POST", "/setup-keys", {
            "name": req["name"], "type": "one-off", "expires_in": int(req["expires_in"]),
            "auto_groups": ids, "usage_limit": 1, "ephemeral": False},
            f"setup key {req['name']}: create")
        if new is not None:
            out["secrets"]["setup_key"] = new["key"]
    else:
        raise ApiError(f"unknown action {action}")
    json.dump(out, sys.stdout)


if __name__ == "__main__":
    try:
        main()
    except ApiError as e:
        json.dump({"error": str(e)}, sys.stdout)
        sys.exit(1)
