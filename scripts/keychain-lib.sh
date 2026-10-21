# shellcheck shell=bash
# Source this file. Keychain writes that keep the value out of argv: the command line is
# built by the printf builtin and fed to `security -i` on stdin. Service "homelab".

kc_service=homelab

# Quote a value for one `security -i` command line: wrap in double quotes, escape \ and ".
kc_quote() {
  local v=$1
  v=${v//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

kc_exists() { security find-generic-password -s "$kc_service" -a "$1" >/dev/null 2>&1; }

# Store stdin as the password of a new Keychain item, then read it back and compare.
# Never overwrites an existing item (no -U). Values must be one printable line
# (`security -w` prints anything else hex-encoded).
kc_store_stdin() {
  local account=$1 value back
  value="$(cat)"
  [ -n "$value" ] || { echo "keychain: nothing to store for $account" >&2; return 1; }
  printf 'add-generic-password -s %s -a %s -w %s\n' \
    "$kc_service" "$account" "$(kc_quote "$value")" | security -i >/dev/null 2>&1 || return 1
  back="$(security find-generic-password -s "$kc_service" -a "$account" -w 2>/dev/null)" || return 1
  [ "$back" = "$value" ]
}
