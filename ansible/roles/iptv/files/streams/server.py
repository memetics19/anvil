#!/usr/bin/env python3
"""On-demand stream helper and web TV page for the IPTV lineup.

GET / is the web TV page; its assets are under /static/ (a fixed list, read into memory
at start; no request reaches the filesystem). GET /guide.json gives now/next for every
lineup channel (IPTV_LINEUP) from the XMLTV guide at IPTV_GUIDE, parsed again only when
that file changes. Page, guide and streams share one origin, so the page needs no CORS.

GET /<id> (or /<id>.ts) runs `streamlink --stdout <source> <quality>` for that channel and
relays the MPEG-TS to the client until either side ends. Nothing runs while nobody
watches. Channels come from IPTV_CHANNELS ({"id": "source URL"}), set by the role from
iptv/channels.yml; any other path is a 404.

Answers 503 when IPTV_MAX_STREAMS streams already run (the container is memory-capped)
and 504 when streamlink produces no data within IPTV_START_TIMEOUT seconds (for example
when the channel is not live). A stream that stalls for that long is ended, and so is a
client that stops reading for IPTV_CLIENT_TIMEOUT seconds, so neither holds a slot. A client
that closes the connection (a player switching channel) frees its slot at once.
"""
import datetime as dt
import gzip
import hashlib
import json
import os
import select
import signal
import subprocess
import sys
import threading
import time
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHANNELS = json.loads(os.environ["IPTV_CHANNELS"])
# [{"id", "name", "number"}] in lineup order: what the page and guide.json list.
LINEUP = json.loads(os.environ.get("IPTV_LINEUP", "[]"))
GUIDE = os.environ.get("IPTV_GUIDE", "/guide/guide.xml")
WEB_DIR = os.environ.get("IPTV_WEB_DIR", "/app/web")
PORT = int(os.environ.get("IPTV_PORT", "34401"))
MAX_STREAMS = int(os.environ.get("IPTV_MAX_STREAMS", "2"))
TIMEOUT = int(os.environ.get("IPTV_START_TIMEOUT", "25"))
CLIENT_TIMEOUT = int(os.environ.get("IPTV_CLIENT_TIMEOUT", "30"))
QUALITY = os.environ.get("IPTV_QUALITY", "best")
CHUNK = 64 * 1024

slots = threading.BoundedSemaphore(MAX_STREAMS)

# The only files served: URL path -> (file in WEB_DIR, content type).
WEB_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/static/app.css": ("app.css", "text/css; charset=utf-8"),
    "/static/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/static/mpegts.js": ("mpegts.js", "text/javascript; charset=utf-8"),
    "/static/mpegts.LICENSE.txt": ("mpegts.LICENSE.txt", "text/plain; charset=utf-8"),
    "/static/mpegts.js.LICENSE.txt": ("mpegts.js.LICENSE.txt", "text/plain; charset=utf-8"),
}
# Same-origin only: no inline script, no other hosts. blob: is the MSE media source.
PAGE_HEADERS = {
    "Content-Security-Policy": "default-src 'none'; script-src 'self'; style-src 'self'; "
                               "img-src 'self' data:; connect-src 'self'; media-src 'self' blob:; "
                               "base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
    "Referrer-Policy": "no-referrer",
}


def log(msg):
    print(time.strftime("%Y-%m-%dT%H:%M:%S"), msg, file=sys.stderr, flush=True)


def stop(proc):
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        proc.wait(5)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        proc.wait()


def load_web():
    """URL path -> (content type, body, gzipped body, etag)."""
    web = {}
    for path, (name, ctype) in WEB_FILES.items():
        with open(os.path.join(WEB_DIR, name), "rb") as f:
            body = f.read()
        etag = '"' + hashlib.sha256(body).hexdigest()[:16] + '"'
        web[path] = (ctype, body, gzip.compress(body, 9, mtime=0), etag)
    return web


def xmltv_time(stamp):
    return int(dt.datetime.strptime(stamp.strip(), "%Y%m%d%H%M%S %z").timestamp())


class Guide:
    """Programmes per lineup channel from the XMLTV file, parsed again when it changes
    (the grabber replaces it with a rename, so the directory is mounted, not the file)."""

    def __init__(self, path):
        self.path = path
        self.key = None
        self.programmes = {}
        self.lock = threading.Lock()

    def _parse(self):
        ids = {c["id"] for c in LINEUP}
        out = {cid: [] for cid in ids}
        for p in ET.parse(self.path).getroot().iter("programme"):
            cid = p.get("channel")
            if cid not in ids:
                continue
            try:
                start, stop = xmltv_time(p.get("start", "")), xmltv_time(p.get("stop", ""))
            except ValueError:
                continue
            if stop > start:
                out[cid].append((start, stop, (p.findtext("title") or "").strip()))
        for progs in out.values():
            progs.sort()
        return out

    def current(self):
        """(programmes, guide present)"""
        try:
            st = os.stat(self.path)
        except OSError:
            return {}, False
        key = (st.st_ino, st.st_mtime_ns, st.st_size)
        with self.lock:
            if key != self.key:
                try:
                    self.programmes = self._parse()
                except (OSError, ET.ParseError) as e:
                    log(f"guide: cannot read {self.path}: {e}")
                    self.programmes = {}
                self.key = key
            return self.programmes, bool(self.programmes)

    def now_next(self, now=None):
        now = int(time.time()) if now is None else now
        programmes, present = self.current()
        channels = []
        for c in sorted(LINEUP, key=lambda c: int(c["number"])):
            progs = programmes.get(c["id"], [])
            cur = next((p for p in progs if p[0] <= now < p[1]), None)
            after = cur[1] if cur else now
            nxt = next((p for p in progs if p[0] >= after), None)
            channels.append({
                "id": c["id"], "name": c["name"], "number": int(c["number"]),
                "now": {"title": cur[2], "start": cur[0], "stop": cur[1]} if cur else None,
                "next": {"title": nxt[2], "start": nxt[0], "stop": nxt[1]} if nxt else None,
            })
        return {"time": now, "guide": present, "channels": channels}


WEB = {}
guide = Guide(GUIDE)


class Handler(BaseHTTPRequestHandler):
    # HTTP/1.0: the body runs until the connection closes (no length, no chunking).
    protocol_version = "HTTP/1.0"
    server_version = "iptv-streams"

    def log_message(self, fmt, *args):
        pass

    def _plain(self, code, text, body=True):
        data = (text + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if body:
            self.wfile.write(data)

    def _channel(self):
        cid = self.path.split("?", 1)[0].strip("/")
        return cid[:-3] if cid.endswith(".ts") else cid

    def _send(self, code, ctype, data, body=True, headers=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if body:
            self.wfile.write(data)

    def _web(self, path, body=True):
        """The page and its assets (exact paths only), the guide. False if not one of them."""
        if path == "/guide.json":
            data = json.dumps(guide.now_next(), separators=(",", ":")).encode()
            self._send(200, "application/json", data, body, {"Cache-Control": "no-cache"})
            return True
        asset = WEB.get(path)
        if asset is None:
            return False
        ctype, raw, gz, etag = asset
        headers = {"Cache-Control": "no-cache", "ETag": etag, "Vary": "Accept-Encoding"}
        if path == "/":
            headers.update(PAGE_HEADERS)
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            for k, v in headers.items():
                self.send_header(k, v)
            self.end_headers()
            return True
        if "gzip" in self.headers.get("Accept-Encoding", ""):
            headers["Content-Encoding"] = "gzip"
            raw = gz
        self._send(200, ctype, raw, body, headers)
        return True

    def do_HEAD(self):
        if self._web(self.path.split("?", 1)[0], body=False):
            return
        cid = self._channel()
        if cid == "health":
            return self._plain(200, "ok", body=False)
        if cid not in CHANNELS:
            return self._plain(404, "unknown channel", body=False)
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.end_headers()

    def do_GET(self):
        if self._web(self.path.split("?", 1)[0]):
            return
        cid = self._channel()
        if cid == "health":
            return self._plain(200, "ok")
        source = CHANNELS.get(cid)
        if source is None:
            return self._plain(404, "unknown channel")
        if not slots.acquire(blocking=False):
            log(f"{cid}: refused, {MAX_STREAMS} streams already running")
            return self._plain(503, "too many streams")
        try:
            self._relay(cid, source)
        finally:
            slots.release()

    @staticmethod
    def _next(fd, sock):
        """The next stream chunk; b"" when the stream ends or stalls for TIMEOUT seconds;
        None when the client has closed the connection (a player that switched channel), so
        its slot is freed at once instead of at the next write."""
        while True:
            ready, _, _ = select.select([fd, sock], [], [], TIMEOUT)
            if sock in ready:
                try:
                    if not sock.recv(4096):  # the client sends nothing after its request
                        return None
                except OSError:
                    return None
            if fd in ready:
                return os.read(fd, CHUNK)
            if not ready:
                return b""

    def _relay(self, cid, source):
        proc = subprocess.Popen(
            ["streamlink", "--stdout", "--loglevel", "warning", "--ringbuffer-size", "8M",
             source, QUALITY],
            stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, start_new_session=True)
        fd = proc.stdout.fileno()
        sock = self.connection
        # A write that cannot finish in time (client stopped reading) raises TimeoutError.
        sock.settimeout(CLIENT_TIMEOUT)
        sent = 0
        started = time.monotonic()
        try:
            first = self._next(fd, sock)
            if first is None:
                return
            if not first:
                log(f"{cid}: no stream within {TIMEOUT}s (not live?)")
                return self._plain(504, "channel is not streaming")
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            log(f"{cid}: started")
            data = first
            while data:
                self.wfile.write(data)
                sent += len(data)
                data = self._next(fd, sock)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except TimeoutError:
            log(f"{cid}: client stopped reading for {CLIENT_TIMEOUT}s, ending")
        finally:
            stop(proc)
            if sent:
                log(f"{cid}: ended after {int(time.monotonic() - started)}s, {sent // 1048576} MiB")


class Server(ThreadingHTTPServer):
    daemon_threads = True


if __name__ == "__main__":
    WEB.update(load_web())
    log(f"listening on :{PORT}, channels: {', '.join(sorted(CHANNELS))}, guide: {GUIDE}")
    Server(("", PORT), Handler).serve_forever()
