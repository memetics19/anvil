"""GPU price watcher: cards with more than 16 GB of video memory under a price, from Indian
shops, used listings and eBay (role watchers). Each source is a small parser. A source that
fails or refuses us is skipped and logged, never the whole run."""
import html
import json
import logging
import re
import urllib.parse
import urllib.request
from base64 import b64encode

from . import common

log = logging.getLogger("watchers.gpu")

# Memory of cards whose titles often leave it out. Only cards with more than 16 GB matter.
KNOWN_VRAM = [
    (r"rtx\s?5090", 32), (r"rtx\s?4090", 24), (r"rtx\s?3090", 24), (r"titan\s?rtx", 24),
    (r"rx\s?7900\s?xtx", 24), (r"rx\s?7900\s?xt\b", 20), (r"tesla\s?p40", 24),
    (r"\bp40\b", 24), (r"rtx\s?a6000", 48), (r"rtx\s?a5000", 24), (r"rtx\s?a4500", 20),
    (r"rtx\s?6000\s?ada", 48), (r"rtx\s?5000\s?ada", 32), (r"rtx\s?4000\s?ada", 20),
]
# Things that are not a card but share its name.
NOT_A_CARD = re.compile(
    r"(?i)\b(water\s?block|waterblock|backplate|bracket|riser|cable|fan|cooler|thermal|"
    r"sticker|decal|skin|laptop|notebook|mouse|keyboard|headset|holder|stand|box only)\b")
MIN_PRICE_INR = 8000  # below this it is an accessory, a scam or a rental


def vram_gb(title):
    """Video memory in GB from the title, or from the model when the title leaves it out."""
    t = title.lower()
    sizes = [int(m) for m in re.findall(r"\b(\d{1,2})\s?g(?:b)?\b(?=\s?(?:gddr|hbm|vram|memory|graphic|$|\s|\)|,))", t)]
    sizes = [s for s in sizes if 4 <= s <= 96]
    if sizes:
        return max(sizes)
    for pattern, gb in KNOWN_VRAM:
        if re.search(pattern, t):
            return gb
    return 0


def qualifies(item, cfg):
    """More than the minimum memory, under the target price, and a card at all."""
    if NOT_A_CARD.search(item["title"]):
        return False
    if item["price_inr"] < MIN_PRICE_INR:
        return False
    return vram_gb(item["title"]) > cfg["min_vram_gb"] and item["price_inr"] < cfg["max_price_inr"]


def inr(text):
    """₹1,23,456.00 or 123456 to 123456."""
    digits = re.sub(r"[^\d.]", "", text or "")
    try:
        return int(float(digits)) if digits else 0
    except ValueError:
        return 0


def _strip(s):
    return html.unescape(re.sub(r"<[^>]+>", " ", s or "")).strip()


# --- parsers (one per kind of page, tested against saved fixtures) ---------------------------

def parse_woocommerce(page, source):
    """WooCommerce search results (PrimeABGB): a title link, then its price (sale price first)."""
    items = []
    for m in re.finditer(r'<h3\s+class="product-title">\s*<a\s+href="([^"]+)"[^>]*>(.*?)</a>', page, re.S):
        block = page[m.end(): m.end() + 3500]
        price_m = re.search(r'<span\s+class="price">(.*?)</span>\s*</div>', block, re.S)
        if not price_m:
            continue
        p = price_m.group(1)
        amounts = re.findall(r"</span>([\d,]+(?:\.\d+)?)</bdi>", p)
        ins = re.search(r"<ins>(.*?)</ins>", p, re.S)
        if ins:
            amounts = re.findall(r"</span>([\d,]+(?:\.\d+)?)</bdi>", ins.group(1)) or amounts
        if amounts:
            items.append({"source": source, "title": _strip(m.group(2)), "url": m.group(1),
                          "price_inr": inr(amounts[0])})
    return items


def parse_mdcomputers(page, source="mdcomputers"):
    """MD Computers search results: a product-entities-title link, then its price (the ins
    span is the sale price)."""
    items = []
    for m in re.finditer(r'<h3\s+class="product-entities-title">\s*<a\s+href="([^"]+)"[^>]*>(.*?)</a>', page, re.S):
        block = page[m.end(): m.end() + 1500]
        price = re.search(r'class="ins">.*?(?:&#8377;|₹)\s*([\d,]+)', block, re.S) or \
            re.search(r'class="price">.*?(?:&#8377;|₹)\s*([\d,]+)', block, re.S)
        if price:
            items.append({"source": source, "title": _strip(m.group(2)), "url": m.group(1),
                          "price_inr": inr(price.group(1))})
    return items


def parse_opencart(page, source, base):
    """OpenCart search results (Vedant): product-thumb blocks."""
    items = []
    for block in re.split(r'<div\s+class="product-thumb', page)[1:]:
        block = block[:15000]
        link = re.search(r'<h4[^>]*>\s*<a\s+href="([^"]+)"[^>]*>(.*?)</a>', block, re.S) or \
            re.search(r'class="name"[^>]*>\s*<a\s+href="([^"]+)"[^>]*>(.*?)</a>', block, re.S)
        price = re.search(r'class="price-(?:new|normal)"[^>]*>(.*?)<', block, re.S) or \
            re.search(r'class="price"[^>]*>\s*([^<]+)<', block, re.S)
        if link and price and inr(price.group(1)):
            items.append({"source": source, "title": _strip(link.group(2)),
                          "url": urllib.parse.urljoin(base, html.unescape(link.group(1))).split("?search=")[0],
                          "price_inr": inr(price.group(1))})
    return items


def parse_flipkart(page, source="flipkart"):
    """Flipkart search results: each product link, its title and the first price after it."""
    items, seen = [], set()
    for m in re.finditer(r'<a[^>]+href="(/[^"]+/p/itm[^"?]+)[^"]*"[^>]*>', page):
        href = m.group(1)
        if href in seen:
            continue
        seg = page[m.start(): m.start() + 3000]
        title = re.search(r'title="([^"]{10,200})"', seg)
        price = re.search(r"₹([\d,]{3,9})", seg)
        if title and price:
            seen.add(href)
            items.append({"source": source, "title": html.unescape(title.group(1)),
                          "url": "https://www.flipkart.com" + href, "price_inr": inr(price.group(1))})
    return items


def parse_amazon(page, source="amazon"):
    """Amazon.in search results: each s-search-result tag (its data-asin comes first), up to
    the next one, with the whole-rupee price."""
    tags = list(re.finditer(r'<div[^>]*?data-asin="([A-Z0-9]{10})"[^>]*?data-component-type="s-search-result"', page))
    items = []
    for n, m in enumerate(tags):
        block = page[m.end(): tags[n + 1].start() if n + 1 < len(tags) else m.end() + 8000]
        title = re.search(r"<h2[^>]*>.*?<span[^>]*>(.*?)</span>", block, re.S)
        price = re.search(r'class="a-price-whole">([\d,]+)', block)
        if title and price:
            items.append({"source": source, "title": _strip(title.group(1)),
                          "url": f"https://www.amazon.in/dp/{m.group(1)}", "price_inr": inr(price.group(1))})
    return items


def _walk(node):
    """Every dict inside a JSON tree."""
    if isinstance(node, dict):
        yield node
        for v in node.values():
            yield from _walk(v)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v)


def parse_olx(page, source="olx"):
    """OLX India search page: the ads in its window.__APP state (any dict with an id, a title
    and price.value.raw)."""
    m = re.search(r"window\.__APP\s*=\s*(\{.*?\});?\s*</script>", page, re.S)
    if not m:
        return []
    items, seen = [], set()
    for it in _walk(json.loads(m.group(1))):
        price = ((it.get("price") or {}).get("value") or {}).get("raw") if isinstance(it.get("price"), dict) else None
        if not (price and it.get("id") and isinstance(it.get("title"), str)) or it["id"] in seen:
            continue
        seen.add(it["id"])
        slug = re.sub(r"[^a-z0-9]+", "-", it["title"].lower()).strip("-")
        items.append({"source": source, "title": it["title"], "price_inr": int(price),
                      "url": f"https://www.olx.in/item/{slug}-iid-{it['id']}", "used": True})
    return items


def parse_ebay(data, cfg, source="ebay"):
    """eBay Browse API results, priced in INR as an estimate (rate, shipping, duty)."""
    items = []
    for it in (data or {}).get("itemSummaries", []):
        try:
            usd = float(it["price"]["value"])
        except (KeyError, TypeError, ValueError):
            continue
        ship = cfg["ebay"]["default_shipping_usd"]
        for opt in it.get("shippingOptions") or []:
            cost = (opt.get("shippingCost") or {}).get("value")
            if cost is not None:
                ship = float(cost)
                break
        estimate = (usd + ship) * cfg["ebay"]["usd_to_inr"] * (1 + cfg["ebay"]["duty_rate"])
        items.append({"source": source, "title": it.get("title") or "", "url": it.get("itemWebUrl") or "",
                      "price_inr": int(estimate), "estimate": True, "used": it.get("condition") != "New"})
    return items


# --- fetching ------------------------------------------------------------------------------

def _ebay_search(cfg, query):
    app_id, cert_id = common.credential("ebay_app_id"), common.credential("ebay_cert_id")
    if not (app_id and cert_id):
        raise common.Blocked("no eBay API keys (official Browse API: eBay forbids scraping its search)")
    basic = b64encode(f"{app_id}:{cert_id}".encode()).decode()
    tok = json.loads(common.fetch(
        "https://api.ebay.com/identity/v1/oauth2/token", accept="application/json",
        data=b"grant_type=client_credentials&scope=https%3A%2F%2Fapi.ebay.com%2Foauth%2Fapi_scope",
        headers={"Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded"}))
    q = urllib.parse.urlencode({"q": query, "limit": "50",
                                "filter": "buyingOptions:{FIXED_PRICE},deliveryCountry:IN"})
    return json.loads(common.fetch(
        "https://api.ebay.com/buy/browse/v1/item_summary/search?" + q, accept="application/json",
        headers={"Authorization": "Bearer " + tok["access_token"], "X-EBAY-C-MARKETPLACE-ID": "EBAY_US",
                 "X-EBAY-C-ENDUSERCTX": "contextualLocation=country%3DIN"}))


def search(source, query, cfg):
    """One query on one source. Returns listings (any price); raises Blocked when refused."""
    q = urllib.parse.quote_plus(query)
    if source == "primeabgb":
        return parse_woocommerce(common.fetch(f"https://www.primeabgb.com/?s={q}&post_type=product", True), source)
    if source == "vedant":
        base = "https://www.vedantcomputers.com/"
        return parse_opencart(common.fetch(f"{base}index.php?route=product/search&search={q}", True), source, base)
    if source == "mdcomputers":
        return parse_mdcomputers(common.fetch(
            f"https://mdcomputers.in/index.php?route=product/search&search={q}", True))
    if source == "flipkart":
        return parse_flipkart(common.fetch(f"https://www.flipkart.com/search?q={q}", True))
    if source == "amazon":
        return parse_amazon(common.fetch(f"https://www.amazon.in/s?k={q}", True))
    if source == "olx":
        # The search page, not its JSON API: robots.txt allows the page and not the API.
        return parse_olx(common.fetch(f"https://www.olx.in/items/q-{q.replace('+', '-')}", True))
    if source == "ebay":
        return parse_ebay(_ebay_search(cfg, query), cfg)
    raise ValueError(source)


def decide(items, state, cfg):
    """The alerts to send: a qualifying listing seen for the first time, or cheaper than when
    it was last alerted. Updates state (url -> last alerted price)."""
    alerts = []
    for it in sorted(items, key=lambda x: x["price_inr"]):
        if not qualifies(it, cfg):
            continue
        key = it["url"] or f'{it["source"]}:{it["title"]}'
        last = state.get(key)
        if last is None or it["price_inr"] < last:
            alerts.append(dict(it, previous=last))
            state[key] = it["price_inr"]
    return alerts


def message(a):
    """A Gotify title and body for one alert."""
    gb = vram_gb(a["title"])
    price = f"₹{a['price_inr']:,}"
    kind = "used" if a.get("used") else "new"
    est = " (estimate: price, shipping and duty)" if a.get("estimate") else ""
    title = f"GPU deal: {gb} GB for {price}{est}"
    drop = f"\nWas ₹{a['previous']:,} when last seen." if a.get("previous") else ""
    body = f"{a['title']}\n{price}, {kind}, from {a['source']}.{drop}\n{a['url']}"
    return title, body


def run(cfg, dry_run=False, state_dir=None):
    """Search every enabled source for every query, alert, and log which sources worked."""
    state = common.State("gpu", state_dir)
    report, found = {}, []
    for source in cfg["sources"]:
        got, errors = 0, []
        try:
            for query in cfg["queries"]:
                try:
                    listings = search(source, query, cfg)
                except TimeoutError:  # a slow shop: one more try for this query
                    common.pause(cfg["pause_seconds"])
                    listings = search(source, query, cfg)
                got += len(listings)
                found.extend(listings)
                common.pause(cfg["pause_seconds"])
        except common.Blocked as e:
            report[source] = f"blocked: {e}"
            continue
        except Exception as e:  # one source never stops the others
            errors.append(f"{type(e).__name__}: {e}")
        if errors:
            report[source] = f"failed after {got} listings: {errors[0]}"
        elif got == 0:
            # Every query empty is more likely a changed page than no cards at all.
            report[source] = "ok but 0 listings (has the page changed?)"
        else:
            report[source] = f"ok ({got} listings)"
    for source, status in report.items():
        log.info("source %s: %s", source, status)
    alerts = decide(found, state.data, cfg)
    for a in alerts:
        title, body = message(a)
        common.notify(cfg, title, body, cfg["priority"], url=a["url"], dry_run=dry_run)
    if not dry_run and common.can_send():
        state.save()
    best = min((i for i in found if qualifies(i, cfg)), key=lambda x: x["price_inr"], default=None)
    log.info("qualifying listings: %d, alerts: %d, cheapest: %s", sum(qualifies(i, cfg) for i in found),
             len(alerts), f"{best['title']} at ₹{best['price_inr']:,} ({best['source']})" if best else "none")
    # How far off the target is, when nothing qualifies: the cheapest big card at any price.
    big = [i for i in found if vram_gb(i["title"]) > cfg["min_vram_gb"] and not NOT_A_CARD.search(i["title"])
           and i["price_inr"] >= MIN_PRICE_INR]
    if big and not best:
        low = min(big, key=lambda x: x["price_inr"])
        log.info("cheapest card over %d GB at any price: %s at ₹%s (%s)", cfg["min_vram_gb"], low["title"],
                 f"{low['price_inr']:,}", low["source"])
    return report, alerts, best

