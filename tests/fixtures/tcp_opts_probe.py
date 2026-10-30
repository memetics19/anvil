#!/usr/bin/env python3
"""Connect to host:port twice: plainly, then with IPv4 options on the SYN (CVE-2026-98432 guard).
For tests/integration/test_role_converge.sh and by hand from a lab VM. Prints results only."""
import socket, sys

host, port = sys.argv[1], int(sys.argv[2])

def connect(options):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(4)
    if options:
        s.setsockopt(socket.IPPROTO_IP, socket.IP_OPTIONS, b"\x01\x01\x01\x00")
    try:
        s.connect((host, port))
        return "connected"
    except socket.timeout:
        return "timed out"
    except OSError as e:
        return "error " + type(e).__name__
    finally:
        s.close()

print("plain:", connect(False))
print("with IP options:", connect(True))
