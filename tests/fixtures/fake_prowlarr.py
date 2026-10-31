"""A fake Prowlarr for tests/unit/test_arr_indexers.sh: indexers, schema, tags and app
profiles, kept in memory. Writes are logged one JSON line each to <dir>/writes.
It checks X-Api-Key against the key in <dir>/config.xml.
Usage: fake_prowlarr.py <dir> <port file>"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

d, port_file = sys.argv[1], sys.argv[2]
# The key is the test's own, random each run, in <dir>/config.xml like Prowlarr's.
KEY = re.search(r"<ApiKey>([0-9a-f]{32})</ApiKey>", open(f"{d}/config.xml").read()).group(1)
state = {
    "indexer": [{"id": 1, "name": "The Pirate Bay", "definitionName": "thepiratebay", "enable": True, "tags": []},
                {"id": 2, "name": "LimeTorrents", "definitionName": "limetorrents", "enable": False, "tags": []}],
    "schema": [{"name": "Knaben", "definitionName": "Knaben", "indexerUrls": ["https://knaben.example/"],
                "fields": [{"name": "baseUrl", "value": None}]},
               {"name": "1337x", "definitionName": "1337x", "indexerUrls": ["https://1337x.example/"],
                "fields": [{"name": "baseUrl", "value": None}]},
               {"name": "EZTV", "definitionName": "eztv", "indexerUrls": ["https://eztv.example/"], "fields": []}],
    "tag": [{"id": 1, "label": "torrent"}],
    "appprofile": [{"id": 7, "name": "Standard"}],
}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body):
        b = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def ok(self):
        if self.headers.get("X-Api-Key") != KEY:
            self.send(401, {"error": "bad key"})
            return False
        return True

    def do_GET(self):
        if not self.ok():
            return
        p = self.path.split("?")[0].removeprefix("/api/v1/")
        key = {"indexer/schema": "schema"}.get(p, p)
        if key in state:
            self.send(200, state[key])
        else:
            self.send(404, {})

    def write(self, method):
        if not self.ok():
            return
        p = self.path.removeprefix("/api/v1/")
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        with open(f"{d}/writes", "a") as f:
            f.write(json.dumps({"method": method, "path": p, "body": body}) + "\n")
        if p == "tag":
            t = {"id": len(state["tag"]) + 1, "label": body["label"]}
            state["tag"].append(t)
            self.send(201, t)
        elif p == "indexer" and body.get("definitionName") == "eztv":
            self.send(400, [{"errorMessage": "Unable to connect to indexer"}])
        elif p == "indexer":
            body["id"] = 100 + len(state["indexer"])
            state["indexer"].append(body)
            self.send(201, body)
        elif p.startswith("indexer/"):
            self.send(202, body)
        else:
            self.send(404, {})

    def do_POST(self):
        self.write("POST")

    def do_PUT(self):
        self.write("PUT")


srv = HTTPServer(("127.0.0.1", 0), H)
open(port_file, "w").write(str(srv.server_port))
srv.serve_forever()
