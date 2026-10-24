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
# YAML on stdin -> the `site` dict as JSON. python3 with PyYAML, else the system Ruby
# (Psych is in its stdlib).
_hl_site_json() {
  local y; y="$(cat)"
  # shellcheck disable=SC2016  # the $stdin below is Ruby, not shell
  printf '%s' "$y" | python3 -c 'import json,sys,yaml; print(json.dumps(yaml.safe_load(sys.stdin)["site"]))' 2>/dev/null ||
    printf '%s' "$y" | ruby -ryaml -rjson -e 'puts JSON.generate(YAML.safe_load($stdin.read)["site"])' 2>/dev/null
}

_hl_main() {
  unset TF_VAR_site_json   # rebuilt below; never keep a stale copy
  PVE_IP="$(_hl_get pve-ip)" && [ -n "$PVE_IP" ] || {
    echo "env.sh: Keychain item pve-ip (service homelab) not found; add it with: security add-generic-password -s homelab -a pve-ip -w <ip>" >&2
    return 1
  }
  VAULT_IP="$(_hl_get vault-ip)" || VAULT_IP=
  export PVE_IP VAULT_IP

  export PROXMOX_VE_ENDPOINT="https://${PVE_IP}:8006/"
  export PROXMOX_VE_INSECURE=true
  # Vault is in the secrets enclave: vault-ip is its enclave address, which the Mac reaches
  # through the route via the Proxmox host (README, Vault). HOMELAB_VAULT_ADDR overrides the
  # whole URL for another path (the gateway name, or an SSH tunnel through the Proxmox host
  # with VAULT_TLS_SERVER_NAME set to the enclave address); HOMELAB_VAULT_CACERT the CA file.
  export VAULT_ADDR="${HOMELAB_VAULT_ADDR:-https://${VAULT_IP}:8200}"
  export VAULT_CACERT="${HOMELAB_VAULT_CACERT:-$HOME/.config/homelab/vault-ca.pem}"

  # The Keychain copy of the site dict (site-bootstrap). Here only for the gateway name;
  # which copy Terraform gets is decided below (site-source.sh).
  _hl_kc=
  if _hl_v="$("$_hl_root/scripts/site-keychain-read.sh")" && [ -n "$_hl_v" ]; then
    _hl_kc="$(printf '%s' "$_hl_v" | _hl_site_json)" || _hl_kc=
    [ -n "$_hl_kc" ] || echo "env.sh: Keychain item site-bootstrap is not YAML with a top-level site dict" >&2
  fi

  # Away from home (on the VPN) the route to Vault's enclave address does not exist, but
  # the gateway does: vault.<gateway domain>, with a public certificate. When the enclave
  # address does not answer in 2 seconds and the gateway does, use the gateway.
  # A parent that already chose the gateway (make, then a script that sources this again)
  # passes the choice on: no second probe, no repeated note.
  _hl_gw=
  if [ -n "${HOMELAB_VAULT_VIA_GATEWAY:-}" ] && [ -z "${HOMELAB_VAULT_ADDR:-}" ]; then
    export VAULT_ADDR="https://vault.$HOMELAB_VAULT_VIA_GATEWAY" VAULT_CACERT="$HOMELAB_VAULT_VIA_CACERT"
    _hl_gw=$HOMELAB_VAULT_VIA_GATEWAY
  elif [ -z "${HOMELAB_VAULT_ADDR:-}" ] && [ -n "$VAULT_IP" ] && [ -n "$_hl_kc" ] &&
    [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/sys/health" 2>/dev/null)" = 000 ]; then
    _hl_gw="$(printf '%s' "$_hl_kc" | jq -r '((.gateway.subdomain // "") | tostring | if . == "" then "" else . + "." end) + (.domain // "")' 2>/dev/null)" || _hl_gw=
    for _hl_v in /etc/ssl/cert.pem /etc/ssl/certs/ca-certificates.crt; do
      if [ -n "$_hl_gw" ] && [ "$_hl_gw" != "." ] && [ -f "$_hl_v" ] &&
        [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 --cacert "$_hl_v" "https://vault.$_hl_gw/v1/sys/health" 2>/dev/null)" != 000 ]; then
        export VAULT_ADDR="https://vault.$_hl_gw" VAULT_CACERT="$_hl_v"
        export HOMELAB_VAULT_VIA_GATEWAY="$_hl_gw" HOMELAB_VAULT_VIA_CACERT="$_hl_v"
        echo "env.sh: Vault's enclave address does not answer (away from home?): using the gateway, vault.<gateway domain>" >&2
        break
      fi
    done
  fi
  # Ansible's hashi_vault lookup (hvac -> requests) asks macOS for system proxies inside a
  # forked worker, which crashes it ("A worker was found in a dead state"). Listing the
  # lab hosts in no_proxy makes requests skip that lookup for them.
  export no_proxy="${no_proxy:-$VAULT_IP,$PVE_IP${_hl_gw:+,vault.$_hl_gw}}"

  _hl_v="$(_hl_get pve-api-token)" && [ -n "$_hl_v" ] && export PROXMOX_VE_API_TOKEN="$_hl_v"
  _hl_v="$(_hl_get ceph-s3-access-key)" && [ -n "$_hl_v" ] && export AWS_ACCESS_KEY_ID="$_hl_v"
  _hl_v="$(_hl_get ceph-s3-secret-key)" && [ -n "$_hl_v" ] && export AWS_SECRET_ACCESS_KEY="$_hl_v"
  _hl_v="$(_hl_get vm-sudo-password)" && [ -n "$_hl_v" ] && export ANSIBLE_BECOME_PASSWORD="$_hl_v"

  _hl_v="$(_hl_get vault-init-json)" && [ -n "$_hl_v" ] && \
    _hl_v="$(printf '%s' "$_hl_v" | jq -r '.root_token // empty' 2>/dev/null)" && \
    [ -n "$_hl_v" ] && export VAULT_TOKEN="$_hl_v"

  # Site values for Terraform (var.site_json). scripts/site-source.sh picks the source and
  # fails closed: when VAULT_TOKEN is set, only a genuinely absent kv/homelab/site falls
  # back to the Keychain (site-bootstrap YAML), unless the operator sets
  # HOMELAB_SITE_SOURCE=keychain. On failure TF_VAR_site_json stays unset, so Terraform
  # stops. HOMELAB_SITE_USED (vault | keychain) names the source; it is not a site value.
  # scripts/site-keychain-read.sh decodes the stored forms (compressed, hex or plain).
  unset HOMELAB_SITE_USED
  if _hl_from="$("$_hl_root/scripts/site-source.sh")"; then
    if [ "$_hl_from" = vault ]; then
      _hl_v="$(VAULT_CLIENT_TIMEOUT=5 VAULT_MAX_RETRIES=0 vault kv get -format=json -mount=kv homelab/site 2>/dev/null |
        jq -c '.data.data.site | select(type == "object")' 2>/dev/null)" || _hl_v=
      if [ -n "$_hl_v" ]; then
        export TF_VAR_site_json="$_hl_v" HOMELAB_SITE_USED=vault
        if [ -z "${HOMELAB_STALE_WARNED:-}" ] && [ -n "$_hl_kc" ] && [ "$(printf '%s' "$_hl_v" | jq -S -c . | shasum -a 256)" != "$(printf '%s' "$_hl_kc" | jq -S -c . | shasum -a 256)" ]; then
          # Once per run: make and the scripts it starts source this file again.
          export HOMELAB_STALE_WARNED=1
          echo "env.sh: warning: the Keychain bootstrap copy (site-bootstrap) is stale; Vault is used. Refresh it: scripts/site-to-keychain.sh --yes" >&2
        fi
      else
        echo "env.sh: kv/homelab/site holds no site dict; TF_VAR_site_json not set" >&2
      fi
    elif [ -n "$_hl_kc" ]; then
      export TF_VAR_site_json="$_hl_kc" HOMELAB_SITE_USED=keychain
    fi
  fi
  return 0
}

_hl_main
_hl_rc=$?
unset _hl_v _hl_src _hl_root _hl_kc _hl_from _hl_gw
unset -f _hl_get _hl_site_json _hl_main
if [ -n "$_hl_x" ]; then unset _hl_x; set -x; else unset _hl_x; fi
# shellcheck disable=SC2317
return "$_hl_rc" 2>/dev/null || true
