#!/usr/bin/env python3
"""On-demand stream helper for the IPTV lineup.

GET /<id> (or /<id>.ts) runs `streamlink --stdout <source> <quality>` for that channel and
relays the MPEG-TS to the client until either side ends. Nothing runs while nobody
watches. Channels come from IPTV_CHANNELS ({"id": "source URL"}), set by the role from
iptv/channels.yml; any other path is a 404.

Answers 503 when IPTV_MAX_STREAMS streams already run (the container is memory-capped)
and 504 when streamlink produces no data within IPTV_START_TIMEOUT seconds (for example
when the channel is not live). A stream that stalls for that long is ended, and so is a
client that stops reading for IPTV_CLIENT_TIMEOUT seconds, so neither holds a slot.
"""
import json
import os
import select
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CHANNELS = json.loads(os.environ["IPTV_CHANNELS"])
PORT = int(os.environ.get("IPTV_PORT", "34401"))
MAX_STREAMS = int(os.environ.get("IPTV_MAX_STREAMS", "2"))
TIMEOUT = int(os.environ.get("IPTV_START_TIMEOUT", "25"))
CLIENT_TIMEOUT = int(os.environ.get("IPTV_CLIENT_TIMEOUT", "30"))
QUALITY = os.environ.get("IPTV_QUALITY", "best")
CHUNK = 64 * 1024

slots = threading.BoundedSemaphore(MAX_STREAMS)


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

    def do_HEAD(self):
        cid = self._channel()
        if cid == "health":
            return self._plain(200, "ok", body=False)
        if cid not in CHANNELS:
            return self._plain(404, "unknown channel", body=False)
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.end_headers()

    def do_GET(self):
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

    def _relay(self, cid, source):
        proc = subprocess.Popen(
            ["streamlink", "--stdout", "--loglevel", "warning", "--ringbuffer-size", "8M",
             source, QUALITY],
            stdout=subprocess.PIPE, stdin=subprocess.DEVNULL, start_new_session=True)
        fd = proc.stdout.fileno()
        # A write that cannot finish in time (client stopped reading) raises TimeoutError.
        self.connection.settimeout(CLIENT_TIMEOUT)
        sent = 0
        started = time.monotonic()
        try:
            ready, _, _ = select.select([fd], [], [], TIMEOUT)
            first = os.read(fd, CHUNK) if ready else b""
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
                ready, _, _ = select.select([fd], [], [], TIMEOUT)
                data = os.read(fd, CHUNK) if ready else b""
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
    log(f"listening on :{PORT}, channels: {', '.join(sorted(CHANNELS))}")
    Server(("", PORT), Handler).serve_forever()
