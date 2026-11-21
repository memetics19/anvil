#!/usr/bin/env python3
"""Read-only access to Hermes's own secrets namespace (kv/homelab/assistant/*), from a snapshot
written at deploy time. There is no live Vault connection and no Vault token here: the deploy
reads the namespace and writes it to the store this reads, so a prompt-injected agent can reach
only this fixed set, never Vault itself. Infrastructure key material (the home VPN keys) is left
out of the snapshot entirely.

Environment:
  SECRETS_STORE   path to the JSON snapshot: {"<path>": {"<key>": "<value>"}}
"""
import json
import os

from mcp.server.mcpserver import MCPServer
from mcp.types import ToolAnnotations

STORE = os.environ.get("SECRETS_STORE", "/opt/data/secrets/store.json")
READ = ToolAnnotations(read_only_hint=True, idempotent_hint=True, open_world_hint=False)


def _load():
    try:
        with open(STORE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


mcp = MCPServer("secrets", instructions=(
    "The operator's own assistant secrets (its Vault namespace), as a read-only snapshot taken "
    "at deploy. list_secrets shows what is held, get_secret returns one value. There is no live "
    "Vault here and nothing can be changed; treat every value as sensitive and never repeat one "
    "unless the operator asks for that exact value."))


@mcp.tool(annotations=READ)
def list_secrets() -> dict:
    """The secret paths held and the key names under each. Values are not returned here."""
    return {path: sorted(keys) for path, keys in ((p, d.keys()) for p, d in _load().items())}


@mcp.tool(annotations=READ)
def get_secret(path: str, key: str) -> dict:
    """One secret value, by path and key, e.g. path 'lab-readonly', key 'grafana_url'. Use
    list_secrets first to see what exists."""
    store = _load()
    if path not in store:
        return {"found": False, "note": "no such path; call list_secrets for what exists"}
    if key not in store[path]:
        return {"found": False, "note": "no such key under %s; keys: %s" % (path, sorted(store[path]))}
    return {"found": True, "path": path, "key": key, "value": store[path][key]}


if __name__ == "__main__":
    mcp.run("stdio")
