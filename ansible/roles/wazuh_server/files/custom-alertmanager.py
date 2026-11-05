#!/usr/bin/env python3
"""custom-alertmanager.py: a Wazuh alert into Alertmanager (role wazuh_server).

Wazuh runs it as: custom-alertmanager <alert file> <api_key> <hook_url>, for every alert of
the integration's level and above. api_key carries the level from which an alert is critical.
The alert goes to Alertmanager's API as WazuhAlert, labelled with the host (the agent's name),
the rule and a severity, so it is grouped, inhibited, silenced and routed like every other
alert (docs/monitoring.md, WazuhAlert). It ends by itself 30 minutes later unless it repeats.
Standard library only.
"""
import datetime
import json
import sys
import urllib.request

RUNBOOK = "https://memetics19.github.io/anvil/monitoring/#wazuhalert"


def to_alertmanager(alert, critical_level, now):
    rule = alert.get("rule", {})
    host = alert.get("agent", {}).get("name") or "unknown"
    level = int(rule.get("level", 0))
    return [{
        "labels": {
            "alertname": "WazuhAlert",
            "severity": "critical" if level >= critical_level else "warning",
            "host": host,
            "rule_id": str(rule.get("id", "")),
            "level": str(level),
            "source": "wazuh",
        },
        "annotations": {
            "summary": f"{host}: {rule.get('description', 'Wazuh alert')}",
            "description": (alert.get("full_log") or "")[:1000],
            "runbook": RUNBOOK,
        },
        "startsAt": now.isoformat(),
        "endsAt": (now + datetime.timedelta(minutes=30)).isoformat(),
    }]


def main(argv):
    if len(argv) < 4:
        raise SystemExit("usage: custom-alertmanager <alert file> <critical level> <hook url>")
    with open(argv[1], encoding="utf-8") as f:
        alert = json.load(f)
    critical = int(argv[2]) if argv[2].isdigit() else 12
    body = to_alertmanager(alert, critical, datetime.datetime.now(datetime.timezone.utc))
    req = urllib.request.Request(argv[3], data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()


if __name__ == "__main__":
    main(sys.argv)
