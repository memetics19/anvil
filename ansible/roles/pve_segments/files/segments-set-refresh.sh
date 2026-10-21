#!/usr/bin/env bash
# Refresh one DNS-fed nftables set of the segments table (role pve_segments): resolve a
# host name through the configured resolver (Pi-hole) and add its A records,
# each with a timeout, so an address the name no longer resolves to drops out by itself. It never
# removes an address early and never adds anything but public unicast IPv4 addresses the
# name resolved to: a failed, empty or oversized answer leaves the set as it is (exit 1, so
# the timer's unit shows the failure).
# Usage: segments-set-refresh.sh <config>  (sourced: TABLE, SET,
#   LOOKUP_HOST, RESOLVER, KEEP (nft timeout, e.g. 24h), MAX, SIZE (the set's size; when
#   the answer would not fit next to the addresses kept from earlier answers, the set is
#   replaced by the answer instead), and optionally EXPECT: a
#   space-separated list of CIDRs the addresses must fall in, others are ignored)
set -euo pipefail
conf=${1:?usage: segments-set-refresh.sh <config>}
# shellcheck source=/dev/null
. "$conf"
: "${TABLE:?}" "${SET:?}" "${LOOKUP_HOST:?}" "${RESOLVER:?}" "${KEEP:?}" "${MAX:?}"
[[ $TABLE =~ ^[a-z][a-z0-9_]*$ && $SET =~ ^[a-z][a-z0-9_]*$ ]] || { echo "segments-set-refresh: bad table or set name" >&2; exit 2; }
[[ $KEEP =~ ^[0-9]+[smhd]$ && $MAX =~ ^[0-9]+$ ]] || { echo "segments-set-refresh: bad KEEP or MAX" >&2; exit 2; }
NFT=${NFT:-nft}
DIG=${DIG:-dig}

EXPECT=${EXPECT:-}
SIZE=${SIZE:-64}
[[ $SIZE =~ ^[0-9]+$ ]] || { echo "segments-set-refresh: bad SIZE" >&2; exit 2; }

ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) + (b << 16) + (c << 8) + d )); }

# 0 when $1 is inside one of the CIDRs in EXPECT (or EXPECT is empty).
expected() {
  [ -n "$EXPECT" ] || return 0
  local c net bits ip mask
  ip=$(ip2int "$1")
  for c in $EXPECT; do
    net=${c%/*}; bits=${c#*/}
    [[ $net =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ && $bits =~ ^[0-9]+$ && $bits -le 32 ]] || continue
    mask=$(( bits == 0 ? 0 : (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( ip & mask )) -eq $(( $(ip2int "$net") & mask )) ] && return 0
  done
  return 1
}

# 0 when $1 is a dotted quad outside the private, shared, loopback, link-local,
# documentation, benchmark, multicast and reserved ranges.
public_ipv4() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  for o in "$a" "$b" "$c" "$d"; do
    [[ $o =~ ^[0-9]{1,3}$ ]] && [ "$o" -le 255 ] || return 1
  done
  case $a in 0|10|127) return 1 ;; esac
  [ "$a" -ge 224 ] && return 1
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 0 ] && { [ "$c" -eq 0 ] || [ "$c" -eq 2 ]; } && return 1
  [ "$a" -eq 198 ] && { [ "$b" -eq 18 ] || [ "$b" -eq 19 ]; } && return 1
  [ "$a" -eq 198 ] && [ "$b" -eq 51 ] && [ "$c" -eq 100 ] && return 1
  [ "$a" -eq 203 ] && [ "$b" -eq 0 ] && [ "$c" -eq 113 ] && return 1
  return 0
}

if ! answer=$("$DIG" +short +time=3 +tries=2 A "$LOOKUP_HOST" @"$RESOLVER" 2>/dev/null); then
  echo "segments-set-refresh: lookup failed; set unchanged" >&2
  exit 1
fi
addrs=()
while IFS= read -r line; do
  [[ $line =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue   # CNAME targets
  if ! public_ipv4 "$line"; then
    echo "segments-set-refresh: ignoring a non-public address in the answer" >&2
  elif ! expected "$line"; then
    echo "segments-set-refresh: ignoring an address outside EXPECT" >&2
  else
    addrs+=("$line")
  fi
done < <(printf '%s\n' "$answer" | sort -u)

if [ ${#addrs[@]} -eq 0 ]; then
  echo "segments-set-refresh: no usable address; set unchanged" >&2
  exit 1
fi
if [ ${#addrs[@]} -gt "$MAX" ]; then
  echo "segments-set-refresh: ${#addrs[@]} addresses (more than $MAX); set unchanged" >&2
  exit 1
fi

# `add element` does not restart the timeout of an address already in the set: such an
# address is deleted and added again, in the same transaction.
present=$("$NFT" list set inet "$TABLE" "$SET" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
others=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  printf '%s\n' "${addrs[@]}" | grep -qxF "$p" || others=$((others + 1))
done <<<"$present"
if [ $((others + ${#addrs[@]})) -gt "$SIZE" ]; then
  # Full: the set becomes exactly this answer (in one transaction).
  {
    printf 'flush set inet %s %s\n' "$TABLE" "$SET"
    for a in "${addrs[@]}"; do
      printf 'add element inet %s %s { %s timeout %s }\n' "$TABLE" "$SET" "$a" "$KEEP"
    done
  } | "$NFT" -f -
  echo "segments-set-refresh: set full; replaced by the ${#addrs[@]} current address(es)"
  exit 0
fi
{
  for a in "${addrs[@]}"; do
    if printf '%s\n' "$present" | grep -qxF "$a"; then
      printf 'delete element inet %s %s { %s }\n' "$TABLE" "$SET" "$a"
    fi
    printf 'add element inet %s %s { %s timeout %s }\n' "$TABLE" "$SET" "$a" "$KEEP"
  done
} | "$NFT" -f -
echo "segments-set-refresh: ${#addrs[@]} address(es) refreshed"
