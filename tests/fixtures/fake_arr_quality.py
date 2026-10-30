"""A fake Sonarr and Radarr for tests/unit/test_arr_quality.sh: the quality profile and quality
definition endpoints only. Each app checks X-Api-Key against the key in its config.xml.
Usage: fake_arr_quality.py <dir> <sonarr port> <radarr port>
<dir>/<app>/config.xml hold the keys, <dir>/<app>.json the state, written on every change."""
import json
import re
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
lock = threading.Lock()


def q(i, name, res):
    return {"id": i, "name": name, "source": "web", "resolution": res}


# Lowest to highest, as the apps list them. Sonarr groups its web qualities.
SCHEMA = {
    "sonarr": [
        {"quality": q(1, "SDTV", 480)}, {"quality": q(4, "HDTV-720p", 720)},
        {"id": 1001, "name": "WEB 720p", "items": [{"quality": q(5, "WEBDL-720p", 720)}, {"quality": q(14, "WEBRip-720p", 720)}]},
        {"quality": q(9, "HDTV-1080p", 1080)},
        {"id": 1002, "name": "WEB 1080p", "items": [{"quality": q(3, "WEBDL-1080p", 1080)}, {"quality": q(15, "WEBRip-1080p", 1080)}]},
        {"quality": q(7, "Bluray-1080p", 1080)}, {"quality": q(20, "Bluray-1080p Remux", 1080)},
        {"id": 1003, "name": "WEB 2160p", "items": [{"quality": q(18, "WEBDL-2160p", 2160)}, {"quality": q(17, "WEBRip-2160p", 2160)}]},
        {"quality": q(21, "Bluray-2160p Remux", 2160)},
    ],
    "radarr": [
        {"quality": q(1, "SDTV", 480)}, {"quality": q(6, "Bluray-720p", 720)},
        {"quality": q(3, "WEBDL-1080p", 1080)}, {"quality": q(7, "Bluray-1080p", 1080)},
        {"quality": q(30, "Remux-1080p", 1080)}, {"quality": q(18, "WEBDL-2160p", 2160)},
        {"quality": q(22, "BR-DISK", 1080)},
    ],
}


def key(app):
    return re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", (root / app / "config.xml").read_text()).group(1)


def state(app):
    p = root / f"{app}.json"
    if p.exists():
        return json.loads(p.read_text())
    s = {"profiles": [{"id": 4, "name": "HD-1080p", "cutoff": 3, "upgradeAllowed": False,
                       "items": [dict(i, allowed=False) for i in SCHEMA[app]]}],
         "defs": [{"id": n, "quality": {"name": name}, "minSize": 35 if "2160" in name else 4}
                  for n, name in enumerate(["WEBDL-1080p", "WEBDL-2160p", "WEBRip-2160p"], 1)],
         "writes": 0}
    p.write_text(json.dumps(s))
    return s


def handler(app):
    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, code, body=None):
            data = json.dumps(body if body is not None else {}).encode()
            self.send_response(code)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def go(self, method):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"null")
            if self.headers.get("X-Api-Key") != key(app):
                return self.reply(401)
            with lock:
                s = state(app)
                path = self.path.removeprefix("/api/v3")
                if method == "GET" and path == "/qualityprofile/schema":
                    return self.reply(200, {"name": "", "cutoff": 0, "upgradeAllowed": False,
                                            "items": [dict(i, allowed=False) for i in SCHEMA[app]]})
                if method == "GET" and path == "/qualityprofile":
                    return self.reply(200, s["profiles"])
                if method == "GET" and path == "/qualitydefinition":
                    return self.reply(200, s["defs"])
                s["writes"] += 1
                if method == "POST" and path == "/qualityprofile":
                    body["id"] = max(p["id"] for p in s["profiles"]) + 1
                    s["profiles"].append(body)
                elif method == "PUT" and path.startswith("/qualityprofile/"):
                    s["profiles"] = [body if p["id"] == body["id"] else p for p in s["profiles"]]
                elif method == "PUT" and path.startswith("/qualitydefinition/"):
                    s["defs"] = [body if d["id"] == body["id"] else d for d in s["defs"]]
                else:
                    return self.reply(404)
                (root / f"{app}.json").write_text(json.dumps(s))
            self.reply(202, body)

        def do_GET(self):
            self.go("GET")

        def do_POST(self):
            self.go("POST")

        def do_PUT(self):
            self.go("PUT")

    return H


servers = [ThreadingHTTPServer(("127.0.0.1", int(p)), handler(a)) for a, p in zip(["sonarr", "radarr"], sys.argv[2:4])]
threading.Thread(target=servers[1].serve_forever, daemon=True).start()
servers[0].serve_forever()
