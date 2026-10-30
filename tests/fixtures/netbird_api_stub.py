#!/usr/bin/env python3
"""A small in-memory stand-in for the NetBird management API (tests/unit/test_netbird_server.sh).

Serves only what ansible/roles/netbird_server/files/netbird_api.py calls. Starts with a
fresh instance (setup required). Writes every non-GET request as one line to the log file
given as the second argument. Usage: netbird_api_stub.py <port-file> <log-file>
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = "nbp_stubtoken"
state = {"setup": True, "seq": 0, "account": None, "users": [], "groups": [], "policies": [],
         "networks": [], "resources": {}, "routers": {}, "nameservers": [], "keys": [], "tokens": []}
lock = threading.Lock()


def nid():
    state["seq"] += 1
    return f"id{state['seq']}"


def gmin(ids):
    names = {g["id"]: g["name"] for g in state["groups"]}
    return [{"id": i, "name": names.get(i, "?")} for i in ids]


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def reply(self, code, obj=None):
        body = b"" if obj is None else json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n)) if n else None

    def handle_any(self, method):
        path = self.path.split("?")[0].removeprefix("/api")
        parts = [p for p in path.split("/") if p]
        with lock:
            if method != "GET":
                with open(sys.argv[2], "a") as f:
                    f.write(f"{method} {path}\n")
            if path == "/instance":
                return self.reply(200, {"setup_required": state["setup"]})
            if path == "/setup" and method == "POST":
                b = self.body()
                if not state["setup"]:
                    return self.reply(412, {"message": "setup already completed"})
                state["setup"] = False
                state["account"] = {"id": "acc1", "settings": {"network_range": "100.64.0.0/16",
                                                               "peer_login_expiration": 86400}}
                all_id = nid()
                state["groups"].append({"id": all_id, "name": "All"})
                state["policies"].append({"id": nid(), "name": "Default", "description": "",
                                          "enabled": True, "rules": [{"id": nid(), "enabled": True,
                                          "action": "accept", "bidirectional": True, "protocol": "all",
                                          "sources": gmin([all_id]), "destinations": gmin([all_id])}]})
                uid = nid()
                state["users"].append({"id": uid, "email": b["email"], "role": "owner",
                                       "auto_groups": [], "is_blocked": False})
                state["tokens"].append({"id": nid(), "name": "setup", "expiration_date": "2099-01-01T00:00:00Z"})
                return self.reply(200, {"user_id": uid, "email": b["email"],
                                        "personal_access_token": TOKEN})
            if self.headers.get("Authorization") != "Token " + TOKEN:
                return self.reply(401, {"message": "no"})
            b = self.body() if method in ("POST", "PUT") else None
            if parts == ["accounts"]:
                return self.reply(200, [state["account"]])
            if parts[:1] == ["accounts"] and method == "PUT":
                state["account"]["settings"] = b["settings"]
                return self.reply(200, state["account"])
            if parts == ["users", "current"]:
                return self.reply(200, state["users"][0])
            if parts == ["users"]:
                return self.reply(200, state["users"])
            if parts[:1] == ["users"] and len(parts) == 2 and method == "PUT":
                u = next(x for x in state["users"] if x["id"] == parts[1])
                u.update(auto_groups=b["auto_groups"], role=b["role"], is_blocked=b["is_blocked"])
                return self.reply(200, u)
            if parts[:1] == ["users"] and parts[2:] == ["tokens"]:
                if method == "GET":
                    return self.reply(200, state["tokens"])
                t = {"id": nid(), "name": b["name"], "expiration_date": "2099-01-01T00:00:00Z"}
                state["tokens"].append(t)
                return self.reply(200, {"plain_token": "nbp_new", "personal_access_token": t})
            if parts == ["groups"]:
                if method == "GET":
                    return self.reply(200, state["groups"])
                g = {"id": nid(), "name": b["name"]}
                state["groups"].append(g)
                return self.reply(200, g)
            if parts[:1] == ["policies"]:
                if method == "GET":
                    return self.reply(200, state["policies"])
                if method == "DELETE":
                    state["policies"] = [p for p in state["policies"] if p["id"] != parts[1]]
                    return self.reply(200, {})
                p = dict(b, id=parts[1] if len(parts) > 1 else nid())
                p["rules"] = [dict(r, id=r.get("id") or nid(), sources=gmin(r["sources"]),
                                   destinations=gmin(r["destinations"])) for r in b["rules"]]
                state["policies"] = [x for x in state["policies"] if x["id"] != p["id"]] + [p]
                return self.reply(200, p)
            if parts == ["networks"]:
                if method == "GET":
                    return self.reply(200, state["networks"])
                n = dict(b, id=nid())
                state["networks"].append(n)
                state["resources"][n["id"]] = []
                state["routers"][n["id"]] = []
                return self.reply(200, n)
            if parts[:1] == ["networks"] and len(parts) >= 3:
                net, kind = parts[1], parts[2]
                store = state[kind]
                if method == "GET":
                    out = store[net]
                    if kind == "resources":
                        out = [dict(r, groups=gmin(r["groups"])) for r in out]
                    return self.reply(200, out)
                obj = dict(b, id=parts[3] if len(parts) > 3 else nid())
                store[net] = [x for x in store[net] if x["id"] != obj["id"]] + [obj]
                return self.reply(200, obj)
            if parts[:2] == ["dns", "nameservers"]:
                if method == "GET":
                    return self.reply(200, state["nameservers"])
                o = dict(b, id=parts[2] if len(parts) > 2 else nid())
                state["nameservers"] = [x for x in state["nameservers"] if x["id"] != o["id"]] + [o]
                return self.reply(200, o)
            if parts[:1] == ["setup-keys"]:
                if method == "GET":
                    return self.reply(200, state["keys"])
                if method == "PUT":
                    k = next(x for x in state["keys"] if x["id"] == parts[1])
                    k.update(revoked=b["revoked"])
                    return self.reply(200, k)
                k = {"id": nid(), "name": b["name"], "revoked": False, "auto_groups": b["auto_groups"],
                     "key": f"STUBKEY-{state['seq']}"}
                state["keys"].append(k)
                return self.reply(200, k)
            return self.reply(404, {"message": "not in the stub: " + path})

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")

    def do_PUT(self):
        self.handle_any("PUT")

    def do_DELETE(self):
        self.handle_any("DELETE")


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_address[1]))
srv.serve_forever()
