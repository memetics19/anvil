# shellcheck shell=bash
# Source this file (do not execute): `source scripts/env.sh`
# Reads pve-ip / vault-ip, then exports credentials from the macOS Keychain
# (service "homelab"). Never prints values (xtrace is suspended while it runs).
# Missing Keychain items are skipped silently so it works at every bootstrap stage.

# Remember the caller's xtrace state, then switch it off so values can't leak.
_hl_x=
case $- in *x*) _hl_x=1 ;; esac
{ set +x; } 2>/dev/null

# Locate this file (bash and zsh), independent of the caller's cwd.
if [ -n "${BASH_VERSION:-}" ]; then
  _hl_src="${BASH_SOURCE[0]}"
else
  eval '_hl_src=${(%):-%x}'
fi
_hl_root="$(cd "$(dirname "$_hl_src")/.." && pwd)"

_hl_get() { security find-generic-password -s homelab -a "$1" -w 2>/dev/null; }

_hl_main() {
  PVE_IP="$(_hl_get pve-ip)" && [ -n "$PVE_IP" ] || {
    echo "env.sh: Keychain item pve-ip (service homelab) not found; add it with: security add-generic-password -s homelab -a pve-ip -w <ip>" >&2
    return 1
  }
  VAULT_IP="$(_hl_get vault-ip)" || VAULT_IP=
  export PVE_IP VAULT_IP

  export PROXMOX_VE_ENDPOINT="https://${PVE_IP}:8006/"
  export PROXMOX_VE_INSECURE=true
  export VAULT_ADDR="https://${VAULT_IP}:8200"
  export VAULT_CACERT="$HOME/.config/homelab/vault-ca.pem"

  _hl_v="$(_hl_get pve-api-token)" && [ -n "$_hl_v" ] && export PROXMOX_VE_API_TOKEN="$_hl_v"
  _hl_v="$(_hl_get ceph-s3-access-key)" && [ -n "$_hl_v" ] && export AWS_ACCESS_KEY_ID="$_hl_v"
  _hl_v="$(_hl_get ceph-s3-secret-key)" && [ -n "$_hl_v" ] && export AWS_SECRET_ACCESS_KEY="$_hl_v"
  _hl_v="$(_hl_get vm-sudo-password)" && [ -n "$_hl_v" ] && export ANSIBLE_BECOME_PASSWORD="$_hl_v"

  _hl_v="$(_hl_get vault-init-json)" && [ -n "$_hl_v" ] && \
    _hl_v="$(printf '%s' "$_hl_v" | jq -r '.root_token // empty' 2>/dev/null)" && \
    [ -n "$_hl_v" ] && export VAULT_TOKEN="$_hl_v"
  return 0
}

_hl_main
_hl_rc=$?
unset _hl_v _hl_src _hl_root
unset -f _hl_get _hl_main
if [ -n "$_hl_x" ]; then unset _hl_x; set -x; else unset _hl_x; fi
# shellcheck disable=SC2317
return "$_hl_rc" 2>/dev/null || true
