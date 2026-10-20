#!/usr/bin/env bash
# Refuse a Terraform plan (JSON from `terraform show -json <plan>`) that would lose data.
# Usage: scripts/plan-guard.sh <plan.json>
# Exits 1 when the plan:
#   - errored, or is incomplete (`complete == false`: made with -target, or with
#     deferred actions), so it can't be trusted to show everything;
#   - has a `delete` action on any resource (covers destroy and replace);
#   - changes which storage backs a protected VM's disks (interface, datastore, size,
#     path, format or source image), or makes them unknown. Protected: ragnarok,
#     whose disk holds the media library. Tuning options (discard, iothread, cache, ...)
#     may change.
# Prints the offending resource addresses only (no attribute values).
set -euo pipefail

plan=${1:?usage: plan-guard.sh <plan.json>}
protected='["proxmox_virtual_environment_vm.ragnarok"]'

# Read once: the argument may be a pipe, e.g. <(terraform show -json plan).
json=$(cat "$plan" 2>/dev/null) || { echo "plan-guard: cannot read $plan" >&2; exit 1; }
q() { jq "$@" <<<"$json"; }
q -e 'type == "object"' >/dev/null 2>&1 || { echo "plan-guard: $plan is not plan JSON" >&2; exit 1; }

fail=0

if q -e '.errored == true' >/dev/null; then
  echo "plan-guard: the plan errored" >&2; fail=1
fi
if q -e '.complete == false' >/dev/null; then
  echo "plan-guard: the plan is incomplete (-target or deferred actions); plan without -target" >&2; fail=1
fi

deletes=$(q -r '.resource_changes // [] | .[]
  | select(.change.actions | index("delete")) | "\(.address) \(.change.actions | join("+"))"')
if [ -n "$deletes" ]; then
  printf 'plan-guard: refusing delete/replace:\n%s\n' "$deletes" >&2; fail=1
fi

# shellcheck disable=SC2016  # $a and $p are jq variables
disks=$(q -r --argjson p "$protected" '
  def ident: [ (. // [])[] | {interface, datastore_id, size, path_in_datastore,
                              file_format, file_id, import_from} ] | sort_by(.interface);
  .resource_changes // [] | .[]
  | select(.address as $a | $p | index($a))
  | select(.change.actions | index("update") or index("create"))
  | select(((.change.before.disk // null) | ident) != ((.change.after.disk // null) | ident)
           or (.change.after == null) or (.change.after.disk == null))
  | .address')
if [ -n "$disks" ]; then
  printf 'plan-guard: refusing change to protected disks:\n%s\n' "$disks" >&2; fail=1
fi

if [ "$fail" -eq 0 ]; then
  q -r '"plan-guard: ok (" + ([.resource_changes // [] | .[]
          | (if .change.importing then "import" else (.change.actions | join("+")) end)]
          | group_by(.) | map("\(.[0])=\(length)") | join(", ")) + ")"'
fi
exit "$fail"
