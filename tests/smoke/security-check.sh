#!/usr/bin/env bash
# Read-only security checks on one host, run as root by tests/smoke/security.yml.
# Prints one "problem: ..." line per finding and exits 1 when there is any. It never prints
# an address: listeners are named by process and port, keys by file and type.
#
# Usage: security-check.sh <allowed key fingerprints> <allowed listeners> <privileged ok>
#   allowed key fingerprints  comma separated SHA256:... values
#   allowed listeners         comma separated proc/port, port may be *, proc "kernel" for
#                             sockets without a process (nfsd, lockd, WireGuard)
#   privileged ok             comma separated container names allowed to run privileged
set -u
export LC_ALL=C
keys=",${1:-},"
listen=",${2:-},"
priv_ok=",${3:-},"
failed_limit=20
found=0
problem() { echo "problem: $1"; found=1; }

# Only root has uid 0.
others=$(awk -F: '$3 == 0 && $1 != "root" {print $1}' /etc/passwd | paste -sd, -)
[ -z "$others" ] || problem "accounts with uid 0 besides root: $others"

# SSH: keys only, no X11, root by key at most.
sshd_t=$(sshd -T 2>/dev/null)
want() { grep -qx "$1" <<<"$sshd_t" || problem "sshd: $2"; }
want 'passwordauthentication no' "password login is on"
want 'kbdinteractiveauthentication no' "keyboard-interactive login is on"
want 'x11forwarding no' "X11 forwarding is on"
grep -qxE 'permitrootlogin (no|prohibit-password|without-password)' <<<"$sshd_t" ||
  problem "sshd: root may log in with a password"

# Every authorized key is a known one.
for f in /root/.ssh/authorized_keys /root/.ssh/authorized_keys2 /home/*/.ssh/authorized_keys \
  /home/*/.ssh/authorized_keys2 /etc/pve/priv/authorized_keys; do
  [ -s "$f" ] || continue
  while read -r _ fp rest; do
    case "$keys" in *",$fp,"*) ;; *) problem "unknown SSH key in $f (${rest##* })" ;; esac
  done < <(ssh-keygen -lf "$f" 2>/dev/null)
done

# Nothing preloaded into every process.
[ ! -s /etc/ld.so.preload ] || problem "/etc/ld.so.preload is not empty"

# Nothing runs from a temporary directory or from memory only.
for p in /proc/[0-9]*; do
  e=$(readlink "$p/exe" 2>/dev/null) || continue
  case "$e" in
    /memfd:runc_cloned*) ;;
    /tmp/* | /var/tmp/* | /dev/shm/* | /memfd:*) problem "process $(cat "$p/comm" 2>/dev/null) runs from $e" ;;
  esac
done
while read -r f; do
  problem "executable file in a temporary directory: $f"
done < <(find /tmp /var/tmp /dev/shm -xdev -type f -perm /111 2>/dev/null | head -5)

# No miner: by name, by pool port, by the MSR module they load for speed.
miners='xmrig|xmr-stak|minerd|cpuminer|kdevtmpfsi|kinsing|nbminer|t-rex|lolminer|phoenixminer|ethminer|cgminer|bfgminer|srbminer|teamredminer|gminer|nanominer'
while read -r comm; do
  problem "miner process: $comm"
done < <(pgrep -ilf "$miners|stratum\+(tcp|ssl)|--donate-level" | awk '{print $2}' | sort -u)
pools=$(ss -Htn state established 2>/dev/null | awk '{print $4}' |
  grep -cE ':(3333|4444|5555|6666|7777|9999|14433|14444|45560|45700)$')
[ "$pools" = 0 ] || problem "$pools connections to mining pool ports"
! lsmod | grep -qw '^msr' || problem "the msr module is loaded (miners use it)"

# Containers: none privileged unless allowed.
if command -v docker >/dev/null; then
  while read -r name p; do
    [ "$p" = true ] || continue
    case "$priv_ok" in *",$name,"*) ;; *) problem "container $name runs privileged" ;; esac
  done < <(docker ps -q | xargs -r docker inspect -f '{{.Name}} {{.HostConfig.Privileged}}' | sed 's#^/##')
fi

# Every listener on a non-loopback address is expected. A process name is cut at its first
# space ("pveproxy worker" is pveproxy). Sockets without a process are the kernel's.
while read -r line; do
  problem "unexpected listener: $line"
done < <(ss -Htulpn | while read -r proto _ _ _ local _ procs; do
  case "$local" in 127.* | \[::1\]:* | \[fe80* | \[::ffff:127.*) continue ;; esac
  port=${local##*:}
  proc=$(sed -nE 's/^users:\(\("([^"]+)".*/\1/p' <<<"$procs")
  proc=${proc%% *}
  proc=${proc:-kernel}
  case "$listen" in *",$proc/$port,"* | *",$proc/*,"*) ;; *) echo "$proc on $proto/$port" ;; esac
done | sort -u)

# No password guessing going on.
failed=$(journalctl -q --since -24h -u ssh -u sshd --no-pager 2>/dev/null | grep -cE 'Failed password|Invalid user')
[ "$failed" -le "$failed_limit" ] || problem "$failed failed SSH logins in 24 hours"

# The packages an intruder would replace first are as shipped.
pkgs=""
for p in openssh-server sudo login passwd coreutils util-linux procps iproute2 libc-bin libpam-modules systemd; do
  dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'ok installed' && pkgs="$pkgs $p"
done
# shellcheck disable=SC2086
changed=$(dpkg --verify $pkgs 2>/dev/null | awk '$2 != "c" && $1 ~ /^..5/ {print $NF}' | head -5 | paste -sd, -)
[ -z "$changed" ] || problem "changed system files: $changed"

# Security updates install themselves, and a kernel waiting for a reboot does not wait long.
[ "$(apt-config dump APT::Periodic::Unattended-Upgrade 2>/dev/null | sed -nE 's/.*"([0-9]+)".*/\1/p')" = 1 ] ||
  problem "automatic security updates are off"
if [ -f /var/run/reboot-required ] && [ -n "$(find /var/run/reboot-required -mtime +7 2>/dev/null)" ]; then
  problem "a reboot has been due for more than 7 days ($(paste -sd' ' /var/run/reboot-required.pkgs 2>/dev/null))"
fi

exit "$found"
