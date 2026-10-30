#!/usr/bin/env bash
# Runs the test suite by layer. Every tests/<layer>/test_*.sh is found by its folder, so a
# new test runs without anyone listing it here or in CI.
#
#   tests/run.sh unit            fast checks, no root, no lab (macOS or Linux)
#   tests/run.sh integration     real tools: loop devices, ZFS, LVM, nftables, apt (Linux, sudo)
#   tests/run.sh smoke           read-only checks against the live lab (needs the lab and Vault)
#   tests/run.sh e2e             builds a throwaway VM, checks it, deletes it (needs the lab)
#   tests/run.sh all             all four, in that order
#   tests/run.sh unit gateway    only the tests whose name contains "gateway"
#
# Each test prints its own ok and FAIL lines. This prints one line per test and a summary,
# and exits 1 if any test failed.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

layers=(unit integration smoke e2e)
usage() { echo "usage: tests/run.sh {unit|integration|smoke|e2e|all} [name filter]" >&2; exit 2; }

case "${1:-}" in
  all) run_layers=("${layers[@]}") ;;
  unit | integration | smoke | e2e) run_layers=("$1") ;;
  *) usage ;;
esac
filter="${2:-}"

# A test outside a layer folder would never run. Refuse instead of ignoring it.
shopt -s nullglob
stray=(tests/test_*.sh)
shopt -u nullglob
if [ "${#stray[@]}" -gt 0 ]; then
  printf 'FAIL: not in a layer folder, so it would never run: %s\n' "${stray[@]}" >&2
  echo "Move it to tests/unit, tests/integration, tests/smoke or tests/e2e (tests/README.md)." >&2
  exit 1
fi

passed=() failed=() skipped=()
for layer in "${run_layers[@]}"; do
  shopt -s nullglob
  tests=(tests/"$layer"/test_*.sh)
  shopt -u nullglob
  [ "${#tests[@]}" -gt 0 ] || { echo "== $layer: no tests"; continue; }
  echo "== $layer"
  for t in "${tests[@]}"; do
    name=$(basename "$t" .sh)
    name=${name#test_}
    [ -z "$filter" ] || [[ "$name" == *"$filter"* ]] || continue
    log=$(mktemp)
    start=$SECONDS
    bash "$t" >"$log" 2>&1
    rc=$?
    # A test that cannot run here (no sudo, a tool missing) prints SKIP and exits 0. In CI the
    # tests turn that into a failure themselves.
    if [ "$rc" = 0 ] && grep -q '^SKIP' "$log"; then
      printf '  skip  %-24s %s\n' "$name" "$(grep -m1 '^SKIP' "$log" | sed 's/^SKIP:* *//')"
      skipped+=("$layer/$name")
    elif [ "$rc" = 0 ]; then
      printf '  pass  %-24s %3ss\n' "$name" "$((SECONDS - start))"
      passed+=("$layer/$name")
    else
      printf '  FAIL  %-24s %3ss\n' "$name" "$((SECONDS - start))"
      sed 's/^/        /' "$log"
      failed+=("$layer/$name")
    fi
    rm -f "$log"
  done
done

echo "== ${#passed[@]} passed, ${#skipped[@]} skipped, ${#failed[@]} failed"
[ "${#failed[@]}" -eq 0 ] || { printf '   failed: %s\n' "${failed[@]}"; exit 1; }
