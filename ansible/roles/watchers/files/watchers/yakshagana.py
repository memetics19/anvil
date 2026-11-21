"""Yakshagana watcher: new shows in Bengaluru on Tititai (www.tititai.com, its own events API),
each sent to Gotify once (role watchers)."""
import datetime
import json
import logging

from . import common

log = logging.getLogger("watchers.yakshagana")

IST = datetime.timezone(datetime.timedelta(hours=5, minutes=30))
CITY_WORDS = ("bengaluru", "bangalore", "ಬೆಂಗಳೂರು")


def in_city(event):
    """In Bengaluru: its district, or its venue or address names the city."""
    text = " ".join(str(event.get(k) or "") for k in ("district", "venue", "address")).lower()
    return any(w in text for w in CITY_WORDS)


def when(event):
    """The show's start as an aware datetime, or None."""
    raw = event.get("date") or ""
    try:
        return datetime.datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None


def upcoming(events, now=None):
    """Approved, active, not deleted, in Bengaluru, and not over yet."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    out = []
    for e in events:
        start = when(e)
        if not start or start < now - datetime.timedelta(hours=12):
            continue
        if e.get("isDeleted") or e.get("isDraft") or not e.get("active", True):
            continue
        if e.get("approvalStatus") not in (None, "APPROVED"):
            continue
        if in_city(e):
            out.append(e)
    return sorted(out, key=when)


def decide(events, state, now=None):
    """Shows not alerted before. Updates state (event id -> its date)."""
    new = []
    for e in upcoming(events, now):
        if e["_id"] not in state:
            new.append(e)
            state[e["_id"]] = e.get("date")
    return new


def message(e, site):
    """A Gotify title and body for one show."""
    start = when(e).astimezone(IST)
    troupe = ", ".join(e.get("troupeNames") or []) or e.get("organisedBy") or ""
    price = ""
    if e.get("isPaid") or e.get("priceFrom"):
        lo, hi = e.get("priceFrom"), e.get("priceTo")
        price = f"\nTickets: ₹{lo}" + (f" to ₹{hi}" if hi and hi != lo else "") if lo else ""
    title = f"Yakshagana in Bengaluru: {start:%a %d %b, %I:%M %p}"
    link = f"{site.rstrip('/')}/event-details/{e['_id']}"
    body = f"{e.get('name', '').strip()}" + (f" ({troupe})" if troupe else "") + \
        f"\n{(e.get('venue') or e.get('address') or '').strip()}{price}\n{link}"
    return title, body, link


def run(cfg, dry_run=False, state_dir=None):
    """Fetch the events, alert the new Bengaluru shows, and log what was found."""
    y = cfg["yakshagana"]
    state = common.State("yakshagana", state_dir)
    events = json.loads(common.fetch(y["api_url"], accept="application/json"))
    shows = upcoming(events)
    new = decide(events, state.data)
    for e in new:
        title, body, link = message(e, y["site_url"])
        common.notify(cfg, title, body, y["priority"], url=link, dry_run=dry_run)
    if not dry_run and common.can_send():
        state.save()
    log.info("events: %d, upcoming in Bengaluru: %d, new alerts: %d", len(events), len(shows), len(new))
    return shows, new
