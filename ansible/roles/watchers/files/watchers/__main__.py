"""python3 -m watchers gpu|yakshagana|test-notify [--dry-run] [--config FILE] (role watchers)."""
import argparse
import json
import logging
import sys

from . import common, gpu, yakshagana


def main(argv=None):
    p = argparse.ArgumentParser(prog="watchers")
    p.add_argument("job", choices=["gpu", "yakshagana", "test-notify"])
    p.add_argument("--config", default="/etc/watchers/config.json")
    p.add_argument("--dry-run", action="store_true", help="log the alerts, send nothing, keep no state")
    a = p.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(name)s: %(message)s", stream=sys.stdout)
    with open(a.config, encoding="utf-8") as f:
        cfg = json.load(f)
    if a.job == "gpu":
        gpu.run(cfg, dry_run=a.dry_run)
    elif a.job == "yakshagana":
        yakshagana.run(cfg, dry_run=a.dry_run)
    else:
        sent = common.notify(cfg, "Watchers are live",
                             "GPU deals and Yakshagana shows in Bengaluru will arrive here.", 4)
        if not sent:
            print("not sent: no Gotify token (kv/homelab/assistant/watchers, gotify_token)")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
