#!/usr/bin/env bash
# Refresh the nftables set `inet enclave smtp_relay` (role pve_enclave): resolve the SMTP
# relay's host name through Pi-hole (the resolver Vaultwarden uses) and add its A records,
# each with a timeout, so an address the relay stops using drops out by itself. It never
# removes an address early and never adds anything but public unicast IPv4 addresses the
# name resolved to: a failed, empty or oversized answer leaves the set as it is (exit 1, so
# the timer's unit shows the failure).
# Usage: enclave-smtp-relay.sh [config]  (default /etc/enclave/smtp-relay.conf, sourced:
#   SMTP_HOST, RESOLVER, KEEP (nft timeout, e.g. 24h), MAX)
set -euo pipefail
conf=${1:-/etc/enclave/smtp-relay.conf}
# shellcheck source=/dev/null
. "$conf"
: "${SMTP_HOST:?}" "${RESOLVER:?}" "${KEEP:?}" "${MAX:?}"
NFT=${NFT:-nft}
DIG=${DIG:-dig}

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

if ! answer=$("$DIG" +short +time=3 +tries=2 A "$SMTP_HOST" @"$RESOLVER" 2>/dev/null); then
  echo "enclave-smtp-relay: lookup failed; set unchanged" >&2
  exit 1
fi
addrs=()
while IFS= read -r line; do
  [[ $line =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue   # CNAME targets
  if public_ipv4 "$line"; then addrs+=("$line"); else
    echo "enclave-smtp-relay: ignoring a non-public address in the answer" >&2
  fi
done < <(printf '%s\n' "$answer" | sort -u)

if [ ${#addrs[@]} -eq 0 ]; then
  echo "enclave-smtp-relay: no usable address; set unchanged" >&2
  exit 1
fi
if [ ${#addrs[@]} -gt "$MAX" ]; then
  echo "enclave-smtp-relay: ${#addrs[@]} addresses (more than $MAX); set unchanged" >&2
  exit 1
fi

# `add element` does not restart the timeout of an address already in the set: such an
# address is deleted and added again, in the same transaction.
present=$("$NFT" list set inet enclave smtp_relay | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true)
{
  for a in "${addrs[@]}"; do
    if printf '%s\n' "$present" | grep -qxF "$a"; then
      printf 'delete element inet enclave smtp_relay { %s }\n' "$a"
    fi
    printf 'add element inet enclave smtp_relay { %s timeout %s }\n' "$a" "$KEEP"
  done
} | "$NFT" -f -
echo "enclave-smtp-relay: ${#addrs[@]} address(es) refreshed"
