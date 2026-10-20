#!/usr/bin/env bash
# Guardrail test for scripts/plan-guard.sh: it must refuse plans that destroy or
# replace anything, change the identity of ragnarok's disks (the media disk), or that
# errored or were cut down with -target; and it must accept a clean plan.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

guard=scripts/plan-guard.sh
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# plan <file> <jq filter applied to the delete fixture>
plan() { jq "$2" tests/fixtures/plan-delete-ragnarok.json > "$tmp/$1"; }

plan noop.json         '.resource_changes[0].change.actions = ["no-op"]'
plan import.json       '.resource_changes[0].change.actions = ["no-op"] | .resource_changes[0].change.importing = {"id": "x"}'
plan delete.json       '.resource_changes[0].change.actions = ["delete"]'
plan create-del.json   '.resource_changes[0].change.actions = ["create", "delete"]'
plan other-del.json    '.resource_changes[0].address = "proxmox_sdn_vnet.servers" | .resource_changes[0].change.actions = ["delete"]'
plan disk-size.json    '.resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk[0].size = 2048'
plan disk-store.json   '.resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk[0].datastore_id = "other"'
plan disk-gone.json    '.resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk = []'
plan disk-unknown.json '.resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk = null'
plan disk-tune.json    '.resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk[0].discard = "on"'
plan cpu-only.json     '.resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.cores = 2'
plan frigate-disk.json '.resource_changes[0].address = "proxmox_virtual_environment_vm.frigate" | .resource_changes[0].name = "frigate" | .resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk[0].size = 2048'
plan errored.json      '.resource_changes[0].change.actions = ["no-op"] | .errored = true'
plan targeted.json     '.resource_changes[0].change.actions = ["no-op"] | .complete = false'
plan empty.json        'del(.resource_changes)'
plan module-disk.json  '.resource_changes[0].address = "module.vms.proxmox_virtual_environment_vm.ragnarok" | .resource_changes[0].module_address = "module.vms" | .resource_changes[0].change.actions = ["update"] | .resource_changes[0].change.after.disk[0].datastore_id = "other"'
plan no-complete.json  '.resource_changes[0].change.actions = ["no-op"] | del(.complete)'
plan no-errored.json   '.resource_changes[0].change.actions = ["no-op"] | del(.errored)'
printf 'not json' > "$tmp/garbage.json"

fail=0
# expect <file> <0|1>
expect() {
  local f=$1 want=$2 rc
  "$guard" "$f" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq "$want" ]; then echo "ok: $(basename "$f") -> exit $rc"
  else echo "FAIL: $(basename "$f") exit $rc, want $want"; fail=1; fi
}

expect tests/fixtures/plan-delete-ragnarok.json 1
expect "$tmp/noop.json"         0
expect "$tmp/import.json"       0
expect "$tmp/delete.json"       1
expect "$tmp/create-del.json"   1
expect "$tmp/other-del.json"    1
expect "$tmp/disk-size.json"    1
expect "$tmp/disk-store.json"   1
expect "$tmp/disk-gone.json"    1
expect "$tmp/disk-unknown.json" 1
expect "$tmp/disk-tune.json"    0
expect "$tmp/cpu-only.json"     0
expect "$tmp/frigate-disk.json" 0
expect "$tmp/errored.json"      1
expect "$tmp/targeted.json"     1
expect "$tmp/empty.json"        0
expect "$tmp/module-disk.json"  1
expect "$tmp/no-complete.json"  1
expect "$tmp/no-errored.json"   1
expect "$tmp/garbage.json"      1
expect "$tmp/missing.json"      1
expect <(cat "$tmp/targeted.json") 1   # read from a pipe: checked once, not re-read empty
expect <(cat "$tmp/delete.json")   1
expect <(cat "$tmp/noop.json")     0

[ "$fail" -eq 0 ] && echo "PASS: plan guard"
exit "$fail"
