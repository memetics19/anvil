#!/usr/bin/env python3
"""Read-only lab status for Hermes, over Grafana's datasource proxy (VictoriaMetrics).

The token is a Grafana Viewer service account: it can run PromQL reads and nothing else
(writes return 403). No secret is in this file; the token comes from the environment.

Environment:
  GRAFANA_URL         e.g. http://192.0.2.10:3000
  GRAFANA_TOKEN_FILE  path to a file holding a Viewer service-account token (preferred, so
                      the token stays out of the config), or GRAFANA_TOKEN with the value
  DATASOURCE_UID      the metrics datasource uid (default: victoriametrics)
"""
import json
import os
import urllib.parse
import urllib.request

GRAFANA = os.environ.get("GRAFANA_URL", "").rstrip("/")
DS = os.environ.get("DATASOURCE_UID", "victoriametrics")


def _token():
    path = os.environ.get("GRAFANA_TOKEN_FILE", "")
    if path:
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return ""
    return os.environ.get("GRAFANA_TOKEN", "")


TOKEN = _token()

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

READ = ToolAnnotations(read_only_hint=True, idempotent_hint=True, open_world_hint=False)


def promql(query):
    """Run a PromQL instant query and return its result list. Read-only."""
    if not (GRAFANA and TOKEN):
        raise RuntimeError("lab status is not configured (no Grafana URL or token)")
    url = "%s/api/datasources/proxy/uid/%s/api/v1/query?%s" % (
        GRAFANA, DS, urllib.parse.urlencode({"query": query}))
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + TOKEN})
    with urllib.request.urlopen(req, timeout=15) as r:
        body = json.loads(r.read())
    if body.get("status") != "success":
        raise RuntimeError("query failed: %s" % body.get("error", "unknown"))
    return body["data"]["result"]


def _val(series):
    return series["value"][1]


mcp = MCPServer("lab", instructions=(
    "Read-only health of the operator's homelab, from its metrics. Use lab_overview for a "
    "quick 'is anything wrong', service_status for one service, internet_health for the home "
    "line, and metric_query for anything else. It can only read; it changes nothing."))


@mcp.tool(annotations=READ)
def lab_overview() -> dict:
    """Every host and monitored service, and whether each is up right now. The first thing to
    check for 'is anything down'."""
    hosts = {s["metric"].get("host", s["metric"].get("instance", "?")): _val(s) == "1"
             for s in promql('up{job="node"}')}
    probes = {}
    for s in promql("probe_success"):
        m = s["metric"]
        name = m.get("instance") or m.get("target") or m.get("job", "?")
        probes["%s/%s" % (m.get("job", "probe"), name)] = _val(s) == "1"
    hosts_down = sorted(h for h, ok in hosts.items() if not ok)
    svc_down = sorted(n for n, ok in probes.items() if not ok)
    return {
        "all_ok": not hosts_down and not svc_down,
        "hosts_up": sum(hosts.values()), "hosts_total": len(hosts),
        "services_up": sum(probes.values()), "services_total": len(probes),
        "hosts_down": hosts_down, "services_down": svc_down,
    }


@mcp.tool(annotations=READ)
def service_status(name: str) -> dict:
    """Up/down for one host or probed service by name, e.g. 'frigate', 'vault', 'netbird'."""
    out = []
    for s in promql('up{job="node"} or probe_success'):
        m = s["metric"]
        label = m.get("host") or m.get("instance") or m.get("target") or ""
        if name.lower() in label.lower() or name.lower() in m.get("job", "").lower():
            out.append({"name": label or m.get("job"), "job": m.get("job"), "up": _val(s) == "1"})
    if not out:
        return {"name": name, "found": False, "note": "no host or service matches that name"}
    return {"name": name, "found": True, "matches": out}


@mcp.tool(annotations=READ)
def internet_health() -> dict:
    """The home internet line: is it up, and the recent download speed if measured."""
    out = {}
    try:
        isp = promql('probe_success{job="ping"}')
        out["line_up"] = any(_val(s) == "1" for s in isp) if isp else None
    except Exception:
        out["line_up"] = None
    try:
        dl = promql("max(last_over_time(speedtest_download_speed_bps[2h]))")
        if dl:
            out["download_mbps"] = round(float(_val(dl[0])) / 1e6, 1)
    except Exception:
        pass
    return out


@mcp.tool(annotations=READ)
def metric_query(query: str) -> list:
    """Run a read-only PromQL instant query and return each series' labels and value. For
    anything the other tools do not cover, e.g. 'rate(node_network_receive_bytes_total[5m])'."""
    return [{"labels": s["metric"], "value": _val(s)} for s in promql(query)][:50]


if __name__ == "__main__":
    mcp.run("stdio")
