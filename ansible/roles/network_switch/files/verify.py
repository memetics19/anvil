#!/usr/bin/env python3
"""Reachability check after a switch change (role network_switch), run on the controller.

Every INTERVAL seconds for SECONDS seconds, all three checks must pass (each gets two
tries per round): the Proxmox host (TCP to its web UI), Pi-hole (a DNS query over UDP)
and the internet (an HTTPS request). Addresses come from the environment
(VERIFY_PVE_HOST, VERIFY_PVE_PORT, VERIFY_DNS_HOST, VERIFY_DNS_NAME, VERIFY_URL) and are
never printed. Output names the checks only. Exit 0 when every round passed, 1 otherwise.
"""
import os
import random
import socket
import struct
import sys
import time
import urllib.request


def tcp(host, port):
    with socket.create_connection((host, int(port)), timeout=3):
        return True


def dns(server, name):
    qid = random.randint(0, 0xFFFF)
    q = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q += b"".join(bytes([len(p)]) + p.encode() for p in name.rstrip(".").split(".")) + b"\0"
    q += struct.pack(">HH", 1, 1)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(3)
        s.sendto(q, (server, 53))
        data = s.recv(512)
    rid, flags, _, ancount = struct.unpack(">HHHH", data[:8])
    return rid == qid and flags & 0x000F == 0 and ancount > 0


def https(url):
    with urllib.request.urlopen(url, timeout=5) as r:
        return 200 <= r.status < 400


def main():
    env = os.environ
    seconds = int(env.get("VERIFY_SECONDS", "60"))
    interval = int(env.get("VERIFY_INTERVAL", "5"))
    checks = [
        ("proxmox host", lambda: tcp(env["VERIFY_PVE_HOST"], env.get("VERIFY_PVE_PORT", "8006"))),
        ("pi-hole dns", lambda: dns(env["VERIFY_DNS_HOST"], env["VERIFY_DNS_NAME"])),
        ("internet", lambda: https(env["VERIFY_URL"])),
    ]
    deadline = time.monotonic() + seconds
    rounds = 0
    while True:
        rounds += 1
        for name, check in checks:
            ok = False
            for _ in range(2):
                try:
                    ok = bool(check())
                except Exception:
                    ok = False
                if ok:
                    break
                time.sleep(1)
            if not ok:
                print("verify: FAILED %s in round %d" % (name, rounds))
                return 1
        if time.monotonic() >= deadline:
            break
        time.sleep(interval)
    print("verify: ok, %d rounds over %d s (proxmox host, pi-hole dns, internet)" % (rounds, seconds))
    return 0


if __name__ == "__main__":
    sys.exit(main())
