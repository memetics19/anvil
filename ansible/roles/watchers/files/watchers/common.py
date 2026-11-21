"""Shared parts of the watchers: polite HTTP, robots.txt, state, Gotify (role watchers)."""
import http.client
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.robotparser

log = logging.getLogger("watchers")

USER_AGENT = "anvil-watchers/1.0 (homelab price and event alerts, a few requests a day)"
# Some shops answer a script's user agent with an error page. This one is sent only to
# sources marked browser_ua in the config, and robots.txt is still read with USER_AGENT.
BROWSER_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
              "Chrome/130.0 Safari/537.36")


class Blocked(Exception):
    """The source refused us (robots.txt, 403, 429, 503 or a challenge page)."""


_robots = {}


def allowed(url):
    """robots.txt for USER_AGENT. A missing or unreadable file allows."""
    parts = urllib.parse.urlsplit(url)
    root = f"{parts.scheme}://{parts.netloc}"
    if root not in _robots:
        rp = urllib.robotparser.RobotFileParser()
        try:
            req = urllib.request.Request(root + "/robots.txt", headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read().decode("utf-8", "ignore")
            if "<html" in body[:300].lower():
                body = ""
            rp.parse(body.splitlines())
        except (urllib.error.URLError, OSError, ValueError):
            rp.parse([])
        _robots[root] = rp
    return _robots[root].can_fetch(USER_AGENT, url)


CHALLENGE_MARKERS = ("captcha-delivery", "/errors/validatecaptcha", "are you a human",
                     "robot check", "pardon our interruption", "access denied")


def fetch(url, browser_ua=False, accept="text/html", timeout=30, data=None, headers=None):
    """GET (or POST with data) a page politely. Raises Blocked when refused."""
    if not allowed(url):
        raise Blocked("robots.txt disallows it")
    h = {"User-Agent": BROWSER_UA if browser_ua else USER_AGENT, "Accept": accept,
         "Accept-Language": "en-IN,en;q=0.8"}
    h.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=h)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode("utf-8", "ignore")
    except urllib.error.HTTPError as e:
        if e.code in (401, 403, 429, 503):
            raise Blocked(f"HTTP {e.code}") from e
        raise
    except (urllib.error.URLError, ConnectionError, http.client.HTTPException) as e:
        # A bot wall that drops the connection looks like this too.
        raise Blocked(f"connection dropped ({type(e).__name__})") from e
    low = body[:20000].lower()
    if any(m in low for m in CHALLENGE_MARKERS):
        raise Blocked("challenge page")
    return body


class State:
    """A small JSON file under the state directory (systemd StateDirectory)."""

    def __init__(self, name, directory=None):
        directory = directory or os.environ.get("STATE_DIRECTORY", "/var/lib/watchers")
        self.path = os.path.join(directory, name + ".json")
        try:
            with open(self.path, encoding="utf-8") as f:
                self.data = json.load(f)
        except (OSError, ValueError):
            self.data = {}

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(self.data, f, ensure_ascii=False, indent=1, sort_keys=True)
        os.replace(tmp, self.path)


def credential(name):
    """A secret systemd hands over (LoadCredential), or None."""
    d = os.environ.get("CREDENTIALS_DIRECTORY")
    if not d:
        return None
    try:
        with open(os.path.join(d, name), encoding="utf-8") as f:
            return f.read().strip() or None
    except OSError:
        return None


def can_send():
    """True when there is a Gotify token. Without one nothing is sent and nothing is
    remembered as sent, so each alert still arrives once the token is there."""
    return credential("gotify") is not None


def notify(cfg, title, message, priority, url=None, dry_run=False):
    """Send one Gotify message. Without a token (or with dry_run) it is only logged."""
    token = credential("gotify")
    if dry_run or not token:
        log.info("would notify%s: %s | %s", "" if token else " (no Gotify token yet)", title, message)
        return False
    body = {"title": title, "message": message, "priority": priority}
    if url:
        body["extras"] = {"client::notification": {"click": {"url": url}},
                          "client::display": {"contentType": "text/markdown"}}
    req = urllib.request.Request(
        cfg["gotify_url"].rstrip("/") + "/message",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "X-Gotify-Key": token},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        r.read()
    log.info("notified: %s", title)
    return True


def pause(seconds):
    """A pause between requests to one site."""
    time.sleep(seconds)
