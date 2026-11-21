#!/usr/bin/env bash
# Watchers (role watchers): every parser against a fake page (tests/fixtures/watchers), the
# memory filter (more than 16 GB), the price limit in rupees, the eBay estimate, dedupe of
# GPU listings and Yakshagana shows, the Bengaluru filter, and no alert sent without a token.
# Then the role renders: its units, its settings, and no secret in them. Needs no lab and no
# network.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1
command -v python3 >/dev/null || { echo "FAIL python3 not found"; exit 1; }

fail=0
ok() { echo "ok   $1"; }
bad_() { echo "FAIL $1"; fail=1; }
check() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad_ "$1"; fi; }
r=$PWD/ansible/roles/watchers

out=$(PYTHONDONTWRITEBYTECODE=1 python3 - "$r/files" "$PWD/tests/fixtures/watchers" <<'PY'
import json, os, sys, tempfile, datetime
sys.path.insert(0, sys.argv[1])
fx = sys.argv[2]
from watchers import common, gpu, yakshagana

def page(name):
    with open(os.path.join(fx, name), encoding="utf-8") as f:
        return f.read()

def check(name, cond):
    print(("ok   " if cond else "FAIL ") + name)

cfg = {"min_vram_gb": 16, "max_price_inr": 45000, "gotify_url": "http://192.0.2.1:8080",
       "ebay": {"usd_to_inr": 88, "duty_rate": 0.4, "default_shipping_usd": 60}}

# Memory: from the title, or from the model when the title leaves it out.
check("vram: 24 GB from the title", gpu.vram_gb("Example RTX 3090 Gaming 24GB GDDR6X") == 24)
check("vram: 24 GB from the model (Tesla P40)", gpu.vram_gb("EXAMPLE Tesla P40 Graphics Card") == 24)
check("vram: 20 GB for the RX 7900 XT", gpu.vram_gb("Example RX 7900 XT") == 20)
check("vram: 16 GB T4 does not qualify", not gpu.qualifies({"title": "Example NVIDIA T4 16GB", "price_inr": 20000}, cfg))
check("vram: 16 GB A4000 does not qualify", not gpu.qualifies({"title": "Example RTX A4000 16GB", "price_inr": 20000}, cfg))
check("vram: 12 GB card does not qualify", not gpu.qualifies({"title": "Example RTX 3060 12GB", "price_inr": 20000}, cfg))

# Price limit in rupees.
check("price: 44,999 qualifies", gpu.qualifies({"title": "Example RTX 3090 24GB", "price_inr": 44999}, cfg))
check("price: 45,000 does not", not gpu.qualifies({"title": "Example RTX 3090 24GB", "price_inr": 45000}, cfg))
check("price: an accessory at 9,999 does not", not gpu.qualifies({"title": "RTX 3090 24GB Backplate", "price_inr": 9999}, cfg))
check("price: anything under 8,000 does not", not gpu.qualifies({"title": "Example RTX 3090 24GB", "price_inr": 5000}, cfg))
check("price: rupee text parses", gpu.inr("₹1,89,999") == 189999 and gpu.inr("₹44,000.00") == 44000)

# Parsers.
p = gpu.parse_woocommerce(page("primeabgb.html"), "primeabgb")
check("woocommerce: three listings, sale price first", [i["price_inr"] for i in p] == [42500, 189999, 9999])
check("woocommerce: newlines inside tags", p[1]["url"] == "https://shop.example.com/rtx-4090-24gb/")
v = gpu.parse_opencart(page("vedant.html"), "vedant", "https://shop.example.com/")
check("opencart: two listings with prices", [i["price_inr"] for i in v] == [44000, 39000])
check("opencart: the search part of the link is dropped", v[0]["url"] == "https://shop.example.com/example-rx-7900-xtx")
m = gpu.parse_mdcomputers(page("mdcomputers.html"))
check("mdcomputers: sale price, then the only price", [i["price_inr"] for i in m] == [43999, 55000]
      and m[0]["url"].endswith("/example-rtx-3090-24g"))
f = gpu.parse_flipkart(page("flipkart.html"))
check("flipkart: titles and prices", [(i["title"][:19], i["price_inr"]) for i in f] == [("EXAMPLE Tesla P40 G", 31999), ("EXAMPLE RTX 3090 St", 299)])
a = gpu.parse_amazon(page("amazon.html"))
check("amazon: two listings by ASIN", [i["url"][-10:] for i in a] == ["B000000001", "B000000002"] and a[0]["price_inr"] == 145000)
o = gpu.parse_olx(page("olx.html"))
check("olx: ads from the page state, marked used", len(o) == 2 and o[0]["price_inr"] == 38000 and o[0]["used"]
      and o[0]["url"].endswith("-iid-1000000001"))
e = gpu.parse_ebay(json.loads(page("ebay.json")), cfg)
check("ebay: estimate is (price + shipping) x rate x (1 + duty)", e[0]["price_inr"] == int((150 + 50) * 88 * 1.4) and e[0]["estimate"])
check("ebay: default shipping when the listing has none", e[1]["price_inr"] == int((700 + 60) * 88 * 1.4))

# What qualifies across every source, and dedupe.
everything = p + v + m + f + a + o + e
good = sorted(i["title"] for i in everything if gpu.qualifies(i, cfg))
check("filter: exactly the six deals qualify", good == sorted([
    "Example RTX 3090 Turbo 24GB Graphics Card",
    "Example GeForce RTX 3090 Gaming 24GB GDDR6X Graphic Card", "Example Radeon RX 7900 XTX 24GB",
    "EXAMPLE Tesla P40 Graphics Card", "Example RTX 3090 24GB, two years old", "Example Tesla P40 24GB"]))
state = {}
first = gpu.decide(everything, state, cfg)
check("dedupe: first run alerts each deal once", len(first) == 6)
check("dedupe: second run alerts nothing", gpu.decide(everything, state, cfg) == [])
cheaper = [dict(p[0], price_inr=41000)]
again = gpu.decide(cheaper, state, cfg)
check("dedupe: a price drop alerts again, with the old price", len(again) == 1 and again[0]["previous"] == 42500)
check("dedupe: the same price again does not", gpu.decide(cheaper, state, cfg) == [])
title, body = gpu.message(again[0])
check("message: short title with memory and price", title == "GPU deal: 24 GB for ₹41,000")
title, _ = gpu.message(dict(e[0], previous=None))
check("message: eBay says it is an estimate", "estimate" in title)

# Yakshagana: Bengaluru only, upcoming, not deleted, each once.
events = json.loads(page("tititai.json"))
now = datetime.datetime(2029, 12, 1, tzinfo=datetime.timezone.utc)
shows = yakshagana.upcoming(events, now)
check("yakshagana: Bengaluru by district, and by a Kannada address", [s["_id"][-1] for s in shows] == ["1", "2"])
st = {}
check("yakshagana: first run alerts both", len(yakshagana.decide(events, st, now)) == 2)
check("yakshagana: second run alerts none", yakshagana.decide(events, st, now) == [])
t, b, link = yakshagana.message(shows[0], "https://www.tititai.com")
check("yakshagana: date in India time, venue, tickets and link",
      t == "Yakshagana in Bengaluru: Thu 10 Jan, 06:30 PM" and "Example Hall, Bengaluru" in b
      and "₹200 to ₹500" in b and link.endswith("/event-details/000000000000000000000001"))

# No token: nothing is sent, the alert is only logged.
os.environ.pop("CREDENTIALS_DIRECTORY", None)
check("notify: without a token nothing is sent", common.notify(cfg, "t", "m", 4) is False)
with tempfile.TemporaryDirectory() as d:
    os.environ["CREDENTIALS_DIRECTORY"] = d
    check("notify: dry run sends nothing even with a token",
          (open(os.path.join(d, "gotify"), "w").write("x") and common.notify(cfg, "t", "m", 4, dry_run=True)) is False)
    s = common.State("gpu", d); s.data["k"] = 1; s.save()
    check("state: saved and read back", common.State("gpu", d).data == {"k": 1})

# Without a token a run remembers nothing, so the shows still arrive once the token is there.
with tempfile.TemporaryDirectory() as d:
    os.environ.pop("CREDENTIALS_DIRECTORY", None)
    common.fetch = lambda *a, **k: page("tititai.json")
    ycfg = dict(cfg, yakshagana={"api_url": "https://www.example.com/api/events",
                                 "site_url": "https://www.example.com", "priority": 4})
    yakshagana.upcoming.__defaults__ = (now,)
    yakshagana.decide.__defaults__ = (now,)
    _, new = yakshagana.run(ycfg, state_dir=d)
    check("no token: the run finds the shows", len(new) == 2)
    check("no token: nothing is remembered as sent", not os.path.exists(os.path.join(d, "yakshagana.json")))
PY
)
echo "$out"
grep -q '^FAIL' <<<"$out" && fail=1
[ -n "$out" ] || bad_ "the Python checks ran"

# --- the role ------------------------------------------------------------------------------
check "the play runs the role on assistant_servers with tag watchers, after Tetragon" \
  "awk '/^- name: Tetragon/{t=1} t&&/^- name: Watchers/{w=1} w&&/hosts: assistant_servers/{h=1} h&&/role: watchers/{r=1} r&&/tags: \\[watchers\\]/{print \"y\"; exit}' ansible/playbooks/vms.yml | grep -q y"
check "the package uses only the standard library" \
  "! grep -hE '^(import|from) ' $r/files/watchers/*.py | grep -vE '^(import|from) (argparse|base64|datetime|html|http\\.client|json|logging|os|re|sys|time|urllib(\\.[a-z]+)?|\\.)( |$)'"
check "the units sandbox the run (throwaway user, read-only system)" \
  "grep -q '^DynamicUser=yes' $r/templates/watchers@.service.j2 && grep -q '^ProtectSystem=strict' $r/templates/watchers@.service.j2"
check "state lives in /var/lib/watchers" "grep -q '^StateDirectory=watchers' $r/templates/watchers@.service.j2"
check "the token reaches the unit as a credential, not in the environment" \
  "grep -q 'LoadCredential=' $r/templates/watchers@.service.j2 && ! grep -qi 'Environment=.*token' $r/templates/watchers@.service.j2"
check "the secrets are written root-only and never logged" \
  "awk '/The secrets, root-only/,/no_log/' $r/tasks/main.yml | grep -q 'mode: \"0600\"' && awk '/The secrets, root-only/,/no_log/' $r/tasks/main.yml | grep -q 'no_log: true'"
check "the Vault read is never logged" "awk '/from Vault/,/no_log/' $r/tasks/main.yml | grep -q 'no_log: true'"
check "the fixtures hold no real address" "! grep -rhoE '\\b(10|172|192\\.168)\\.[0-9]+\\.[0-9]+\\.[0-9]+\\b' tests/fixtures/watchers"
check "GPU timer every 2 to 4 hours" "grep -qE '^watchers_gpu_interval: [234]h$' $r/defaults/main.yml"

exit $fail
