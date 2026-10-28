#!/usr/bin/env python3
"""zfs-pools.py: the data pools of a Proxmox host, as declared (role zfs_pools).

Usage: zfs-pools.py [--check] [--wipe POOL] [--byid-dir DIR] <pools as JSON>

Each pool is {"name", "layout": mirror|raidz1|raidz2|raidz3, "disks": [<by-id names>],
"proxmox_storage": bool}. For each pool:
  - it exists with exactly these disks: nothing to do
  - it exists with other disks: an error. An existing pool is never changed
  - it does not exist: every disk must be a whole disk, in no pool and not mounted. A disk
    with partitions or signatures (an old filesystem, RAID or ZFS label) is refused, unless
    --wipe names this pool. Then its signatures are wiped first. Then zpool create.
  - proxmox_storage: the pool is added as Proxmox storage (zfspool, VM disks and containers),
    for this node only: in a cluster the storage list is shared, and the pool is only here
It always prints the disks it sees first, so the by-id names to declare are on screen.
--check prints what it would do and changes nothing.
"""
import json
import os
import re
import socket
import subprocess
import sys

LAYOUTS = {"mirror": 2, "raidz1": 3, "raidz2": 4, "raidz3": 5}
NAME_RE = re.compile(r"^[a-z][a-z0-9_-]{0,30}$")
DISK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:+-]*$")


def run(argv, check=True):
    r = subprocess.run(argv, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise SystemExit(f"zfs-pools: {' '.join(argv[:2])} failed: {r.stderr.strip()}")
    return r


def base(dev):
    """The whole disk a device or partition belongs to: sda3 -> sda, nvme0n1p2 -> nvme0n1."""
    name = os.path.basename(dev)
    if os.path.exists(f"/sys/class/block/{name}/partition"):
        return os.path.basename(os.path.dirname(os.path.realpath(f"/sys/class/block/{name}")))
    return name


def disks(byid_dir):
    """Whole disks under byid_dir: {device: {"ids": [...], ...}}."""
    out = {}
    for e in sorted(os.listdir(byid_dir)):
        if re.search(r"-part\d+$", e):
            continue
        dev = os.path.basename(os.path.realpath(os.path.join(byid_dir, e)))
        if os.path.exists(f"/sys/class/block/{dev}/partition"):
            continue
        d = out.setdefault(dev, {"ids": []})
        d["ids"].append(e)
    for dev, d in out.items():
        sysd = f"/sys/class/block/{dev}"
        d["size"] = int(open(f"{sysd}/size").read()) * 512
        d["parts"] = sorted(p for p in os.listdir(sysd) if p.startswith(dev) and os.path.exists(f"{sysd}/{p}/partition"))
        r = run(["lsblk", "-dno", "MODEL,SERIAL", f"/dev/{dev}"], check=False)
        d["model"] = " ".join(r.stdout.split()) or "-"
        r = run(["wipefs", "--noheadings", "--output", "TYPE", f"/dev/{dev}"] + [f"/dev/{p}" for p in d["parts"]], check=False)
        d["signatures"] = sorted(set(r.stdout.split()))
    return out


def mounted():
    devs = set()
    for line in open("/proc/mounts"):
        src = line.split()[0]
        if src.startswith("/dev/"):
            devs.add(base(os.path.realpath(src)))
    for line in open("/proc/swaps").read().splitlines()[1:]:
        devs.add(base(os.path.realpath(line.split()[0])))
    return devs


def vdev_disk(path):
    """The whole disk of a pool member. ZFS partitions a whole disk it is given, so a member
    may be <path>-part1, which need not exist as a link: then the path without -partN."""
    if not os.path.exists(path):
        path = re.sub(r"-part\d+$", "", path)
    return base(os.path.realpath(path))


def pool_members():
    """{pool: set of whole-disk device names} for the imported pools."""
    out = {}
    for name in run(["zpool", "list", "-H", "-o", "name"]).stdout.split():
        devs = set()
        for line in run(["zpool", "status", "-P", name]).stdout.splitlines():
            f = line.split()
            if f and f[0].startswith("/") and not f[0].startswith("/dev/zvol"):
                devs.add(vdev_disk(f[0]))
        out[name] = devs
    return out


def gb(n):
    return f"{n / 1e9:.0f} GB" if n < 1e12 else f"{n / 1e12:.1f} TB"


def main(args):
    check, wipe, byid_dir = False, "", "/dev/disk/by-id"
    while args and args[0].startswith("--"):
        a = args.pop(0)
        if a == "--check":
            check = True
        elif a == "--wipe":
            wipe = args.pop(0)
        elif a == "--byid-dir":
            byid_dir = args.pop(0)
        else:
            raise SystemExit(f"zfs-pools: unknown option {a}")
    if len(args) != 1:
        raise SystemExit(__doc__)
    pools = json.loads(args[0])
    do = "would" if check else "do:"

    errors = []
    seen = {}
    for p in pools:
        n = p.get("name", "")
        if not NAME_RE.match(n) or n in ("rpool", "bpool"):
            errors.append(f"pool name {n!r}: lowercase letters, digits, _ and -, and not rpool or bpool")
        if p.get("layout") not in LAYOUTS:
            errors.append(f"{n}: layout is one of {', '.join(LAYOUTS)}")
        elif len(p.get("disks", [])) < LAYOUTS[p["layout"]]:
            errors.append(f"{n}: {p['layout']} needs at least {LAYOUTS[p['layout']]} disks")
        for d in p.get("disks", []):
            if not DISK_RE.match(d) or re.search(r"-part\d+$", d):
                errors.append(f"{n}: {d!r} is not a whole-disk name under {byid_dir}")
            if d in seen:
                errors.append(f"{d} is in both {seen[d]} and {n}")
            seen[d] = n
    if wipe and wipe not in [p.get("name") for p in pools]:
        errors.append(f"--wipe {wipe}: no such pool declared")
    if errors:
        print("\n".join("error: " + e for e in errors))
        return 1

    all_disks = disks(byid_dir)
    members = pool_members()
    in_pool = {dev: name for name, devs in members.items() for dev in devs}
    busy = mounted()

    print("disks:")
    for dev, d in sorted(all_disks.items()):
        use = f"pool {in_pool[dev]}" if dev in in_pool else ("mounted" if dev in busy else
              ("signatures: " + ",".join(d["signatures"]) if d["signatures"] else "free"))
        ident = min(d["ids"], key=lambda i: (not i.startswith("wwn-"), len(i)))
        print(f"  {ident:<40} {dev:<8} {gb(d['size']):>7}  {d['model']:<28} {use}")

    by_id = {i: dev for dev, d in all_disks.items() for i in d["ids"]}
    plan, rc = [], 0
    for p in pools:
        n, want = p["name"], [by_id.get(d) for d in p["disks"]]
        missing = [d for d, dev in zip(p["disks"], want) if dev is None]
        if missing:
            print(f"error: {n}: no such disk: {', '.join(missing)}")
            rc = 1
            continue
        if n in members:
            if members[n] == set(want):
                print(f"ok: {n} exists with these disks")
            else:
                print(f"error: {n} exists with other disks. anvil never changes an existing pool")
                rc = 1
                continue
        else:
            bad, to_wipe = [], []
            for d, dev in zip(p["disks"], want):
                if dev in in_pool:
                    bad.append(f"{d} is in pool {in_pool[dev]}")
                elif dev in busy:
                    bad.append(f"{d} is mounted")
                elif all_disks[dev]["signatures"] or all_disks[dev]["parts"]:
                    if wipe == n:
                        to_wipe.append((d, dev))
                    else:
                        what = ",".join(all_disks[dev]["signatures"]) or "partitions"
                        bad.append(f"{d} holds {what}. If nothing on it is needed: --wipe {n}")
            if bad:
                print("\n".join(f"error: {n}: {b}" for b in bad))
                rc = 1
                continue
            for d, dev in to_wipe:
                plan.append((f"{do} wipe the signatures on {d} ({dev})",
                             [["wipefs", "--all", f"/dev/{x}"] for x in all_disks[dev]["parts"]] +
                             [["wipefs", "--all", f"{byid_dir}/{d}"]]))
            plan.append((f"{do} create {n}: {p['layout']} of {len(want)} disks",
                         [["zpool", "create", "-o", "ashift=12", "-O", "compression=lz4", "-O", "atime=off",
                           "-O", "xattr=sa", "-O", "acltype=posixacl", n, p["layout"]] +
                          [f"{byid_dir}/{d}" for d in p["disks"]]]))
        if p.get("proxmox_storage"):
            have = run(["pvesm", "status", "--storage", n], check=False).returncode == 0
            if have:
                print(f"ok: {n} is Proxmox storage")
            else:
                plan.append((f"{do} add {n} as Proxmox storage (VM disks and containers)",
                             [["pvesm", "add", "zfspool", n, "--pool", n, "--content", "images,rootdir", "--sparse", "1",
                               "--nodes", socket.gethostname().split(".")[0]]]))
    if rc:
        print("nothing changed")
        return rc
    for msg, cmds in plan:
        print(msg)
        if not check:
            for c in cmds:
                run(c)
    if not plan:
        print("nothing to change")
    elif not check:
        for p in pools:
            health = run(["zpool", "list", "-H", "-o", "health", p["name"]]).stdout.strip()
            print(f"{p['name']}: {health}")
            if health != "ONLINE":
                rc = 1
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
