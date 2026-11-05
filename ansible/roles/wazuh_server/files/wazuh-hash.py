#!/usr/bin/env python3
"""wazuh-hash.py <internal_users.yml>: bcrypt hashes for the indexer's users (role wazuh_server).

Reads {"user": "password", ...} as JSON on stdin and prints {"user": "hash", ...}. A hash the
file already holds is kept when it still matches its password, so a rerun changes nothing.
Passwords never touch the command line.
"""
import json
import re
import sys

import bcrypt

passwords = json.load(sys.stdin)
have = {}
try:
    text = open(sys.argv[1], encoding="utf-8").read()
    for user, h in re.findall(r'(?m)^([a-z]+):\n  hash: "([^"]+)"', text):
        have[user] = h
except FileNotFoundError:
    pass

out = {}
for user, pw in passwords.items():
    old = have.get(user, "")
    try:
        same = old and bcrypt.checkpw(pw.encode(), old.replace("$2y$", "$2b$", 1).encode())
    except ValueError:
        same = False
    out[user] = old if same else bcrypt.hashpw(pw.encode(), bcrypt.gensalt(12)).decode()
print(json.dumps(out))
