"""A fake Bazarr, Sonarr and Radarr in one server, for tests/unit/test_arr_bazarr.sh.
Bazarr's settings, languages, profiles, series and movies and the apps' media management are
kept in memory. Writes are logged one JSON line each to <dir>/writes. Bazarr's key is read
from <dir>/config.yaml, the apps' from <dir>/<app>.xml.
Usage: fake_bazarr.py <dir> <port file>"""
import json
import re
import sys
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer

d, port_file = sys.argv[1], sys.argv[2]
bkey = re.search(r"apikey: ([0-9a-f]{32})", open(f"{d}/config.yaml").read()).group(1)
akey = {a: re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", open(f"{d}/{a}.xml").read()).group(1) for a in ("sonarr", "radarr")}
settings = {"general": {"use_sonarr": False, "use_radarr": False, "use_embedded_subs": True, "enabled_providers": ["podnapisi"],
                        "serie_default_enabled": False, "serie_default_profile": "", "movie_default_enabled": False,
                        "movie_default_profile": ""},
            "sonarr": {"ip": "127.0.0.1", "port": 8989, "ssl": False, "base_url": "/", "apikey": ""},
            "radarr": {"ip": "127.0.0.1", "port": 7878, "ssl": False, "base_url": "/", "apikey": ""},
            "opensubtitlescom": {"username": "", "password": ""}}
languages = [{"code2": c, "name": c, "enabled": False} for c in ("en", "hi", "kn")]
profiles = [{"profileId": 1, "name": "Kannada", "items": [{"id": 1, "language": "kn"}]}]
series = [{"sonarrSeriesId": 5, "profileId": None}, {"sonarrSeriesId": 6, "profileId": 1}]
movies = [{"radarrId": 9, "profileId": None}]
mm = {a: {"id": 1, "importExtraFiles": False, "extraFileExtensions": "srt"} for a in ("sonarr", "radarr")}


def log(method, path, body):
    with open(f"{d}/writes", "a") as f:
        f.write(json.dumps({"method": method, "path": path, "body": body}) + "\n")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=None):
        b = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def app(self):
        """The app the request is for, by its key; None when the key is wrong."""
        k = self.headers.get("X-Api-Key")
        if self.path.startswith("/api/v3/"):
            return next((a for a, v in akey.items() if v == k), None)
        return "bazarr" if k == bkey else None

    def body(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        if self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):
            return urllib.parse.parse_qs(raw)
        return json.loads(raw or "{}")

    def do_GET(self):
        a, p = self.app(), self.path.split("?")[0]
        if not a:
            return self.send(401)
        if a in ("sonarr", "radarr") and p == "/api/v3/config/mediamanagement":
            return self.send(200, mm[a])
        routes = {"/api/system/settings": settings, "/api/system/languages": languages,
                  "/api/system/languages/profiles": profiles, "/api/series": {"data": series},
                  "/api/movies": {"data": movies}}
        self.send(200, routes[p]) if p in routes else self.send(404)

    def do_POST(self):
        a, p = self.app(), self.path.split("?")[0]
        if a != "bazarr":
            return self.send(401)
        form = self.body()
        log("POST", p, form)
        if p == "/api/system/settings":
            for k, v in form.items():
                if k == "languages-enabled":
                    for lang in languages:
                        lang["enabled"] = lang["code2"] in v
                elif k == "languages-profiles":
                    profiles[:] = json.loads(v[0])
                elif k.startswith("settings-"):
                    _, sec, key = k.split("-", 2)
                    val = v if key == "enabled_providers" else v[0]
                    val = {"true": True, "false": False}.get(val, val) if isinstance(val, str) else val
                    settings.setdefault(sec, {})[key] = int(val) if isinstance(val, str) and val.isdigit() else val
        elif p in ("/api/series", "/api/movies"):
            rows, idk, f = (series, "sonarrSeriesId", "seriesid") if p == "/api/series" else (movies, "radarrId", "radarrid")
            for i, pid in zip(form[f], form["profileid"]):
                for r in rows:
                    if str(r[idk]) == i:
                        r["profileId"] = int(pid)
        self.send(204)

    def do_PUT(self):
        a = self.app()
        if a not in ("sonarr", "radarr"):
            return self.send(401)
        b = self.body()
        log("PUT", f"{a}{self.path}", b)
        mm[a] = b
        self.send(202, b)


srv = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_port))
srv.serve_forever()
