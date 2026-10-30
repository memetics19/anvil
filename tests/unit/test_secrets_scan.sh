#!/usr/bin/env bash
# Guardrail test: gitleaks must flag fabricated secrets and private IPs, and must
# not flag documentation-range IPs. Every fake value is assembled at runtime so
# this file itself contains nothing secret-looking.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

fixture=tests/fixtures/leak
report=$(mktemp)
trap 'rm -rf "$fixture" "$report"; rmdir tests/fixtures 2>/dev/null' EXIT

rnd() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }   # 2*N hex chars
b64() { head -c 90 /dev/urandom | base64 | tr -d '=\n+/' | head -c "$1"; }

h=$(rnd 16)
uuid="${h:0:8}-${h:8:4}-${h:12:4}-${h:16:4}-${h:20:12}"
tunnel="eyJ""hIjoi$(b64 120)"
pw="pass""word"
dollar='$'
hash="${dollar}6${dollar}$(b64 8)${dollar}$(b64 86)"
priv="10.""2.0.""10"
doc="192.0.""2.10"
doc2="198.51.""100.7"
pwval=$(rnd 6)

fail=0
# scan_case <name> <content> <expected-rule | NONE>
scan_case() {
  local name=$1 content=$2 want=$3 rc
  rm -rf "$fixture"; mkdir -p "$fixture"
  printf '%s\n' "$content" > "$fixture/$name"
  gitleaks dir "$fixture" --no-banner --config .gitleaks.toml \
    --report-format json --report-path "$report" >/dev/null 2>&1
  rc=$?
  if [ "$want" = NONE ]; then
    [ "$rc" -eq 0 ] || { echo "FAIL: $name should be clean, gitleaks exit $rc"; fail=1; return; }
  else
    if ! { [ "$rc" -eq 1 ] && grep -q "\"RuleID\": \"$want\"" "$report"; }; then
      echo "FAIL: $name should fire $want (exit $rc)"; fail=1; return
    fi
  fi
  echo "ok: $name -> $want"
}

scan_case tunnel.yml    "cloudflare_tunnel_token: $tunnel"          cloudflare-tunnel-token
scan_case password.yml  "${pw}: $pwval"                              generic-password-literal
scan_case setup-key.yml "netbird_setup_key: $uuid"                  netbird-setup-key
scan_case setup-cli.txt "netbird up --setup-key $uuid"              netbird-setup-key
scan_case hash.yml      "hash: $hash"                               password-hash
scan_case private-ip.yml "host: $priv"                              private-ipv4
scan_case doc-ip.yml    "host: $doc"                                NONE
scan_case doc-ip2.yml   "host: $doc2"                               NONE

[ "$fail" -eq 0 ] && echo "PASS: secrets scan guardrails"
exit "$fail"
