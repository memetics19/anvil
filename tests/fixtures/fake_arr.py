"""A fake Radarr, Sonarr and Prowlarr for tests/unit/test_rotate.sh: only the API calls that
anvil rotate makes. Each app checks X-Api-Key against the key in its config.xml.
Usage: fake_arr.py <dir> <radarr port> <sonarr port> <prowlarr port>
<dir>/<app>/config/config.xml hold the keys, <dir>/state.json what Prowlarr was told."""
import json
import re
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
ports = dict(zip(["radarr", "sonarr", "prowlarr"], map(int, sys.argv[2:5])))
lock = threading.Lock()


def key(app):
    xml = (root / app / "config" / "config.xml").read_text()
    return re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", xml).group(1)


def set_key(app, new):
    p = root / app / "config" / "config.xml"
    p.write_text(re.sub(r"<ApiKey>[0-9a-f]{32}</ApiKey>", f"<ApiKey>{new}</ApiKey>", p.read_text()))


def load():
    p = root / "state.json"
    if p.exists():
        return json.loads(p.read_text())
    apps = [{"id": i + 1, "name": n.capitalize(), "implementation": n.capitalize(), "syncLevel": "fullSync",
             "fields": [{"name": "prowlarrUrl", "value": "http://prowlarr"}, {"name": "baseUrl", "value": f"http://{n}"},
                        {"name": "apiKey", "value": key(n)}]} for i, n in enumerate(["radarr", "sonarr"])]
    return {"applications": apps, "syncs": [], "indexer_key": {n: key("prowlarr") for n in ["radarr", "sonarr"]}}


def save(s):
    (root / "state.json").write_text(json.dumps(s))


def handler(app):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body=None):
            data = json.dumps(body if body is not None else {}).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def body(self):
            n = int(self.headers.get("Content-Length") or 0)
            return json.loads(self.rfile.read(n) or b"{}")

        def authed(self):
            if self.headers.get("X-Api-Key") != key(app):
                self.reply(401, {"error": "Unauthorized"})
                return False
            return True

        def do_GET(self):
            if not self.authed():
                return
            with lock:
                s = load()
            if app == "prowlarr" and self.path == "/api/v1/applications":
                return self.reply(200, s["applications"])
            self.reply(404)

        def do_POST(self):
            if not self.authed():
                return
            b = self.body()
            ver = "v1" if app == "prowlarr" else "v3"
            if self.path != f"/api/{ver}/command":
                return self.reply(404)
            with lock:
                s = load()
                if b.get("name") == "ResetApiKey":
                    set_key(app, secrets.token_hex(16))
                elif app == "prowlarr" and b.get("name") == "ApplicationIndexerSync":
                    s["syncs"].append(b)
                    for n in s["indexer_key"]:
                        s["indexer_key"][n] = key("prowlarr")
                else:
                    return self.reply(400)
                save(s)
            self.reply(201, {"name": b.get("name"), "status": "queued"})

        def do_PUT(self):
            if not self.authed():
                return
            m = re.fullmatch(r"/api/v1/applications/(\d+)", self.path)
            if app != "prowlarr" or not m:
                return self.reply(404)
            b = self.body()
            with lock:
                s = load()
                s["applications"] = [b if a["id"] == int(m.group(1)) else a for a in s["applications"]]
                save(s)
            self.reply(202, b)

    return H


with lock:
    save(load())
servers = [ThreadingHTTPServer(("127.0.0.1", p), handler(a)) for a, p in ports.items()]
for srv in servers[1:]:
    threading.Thread(target=srv.serve_forever, daemon=True).start()
servers[0].serve_forever()
