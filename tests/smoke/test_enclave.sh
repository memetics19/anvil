#!/usr/bin/env bash
# The secrets enclave: Vault is unsealed and answers this machine, and no other VM can open
# a connection to Vault or Vaultwarden (tests/smoke/enclave.yml, read-only).
source "$(dirname "$0")/lib.sh"
command -v vault >/dev/null || skip "the vault CLI is missing"
command -v ansible-playbook >/dev/null || skip "ansible-playbook missing"

st=$(VAULT_CLIENT_TIMEOUT=5 VAULT_MAX_RETRIES=0 vault status -format=json 2>/dev/null)
if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["initialized"] and not d["sealed"] else 1)' "$st" 2>/dev/null; then
  ok "Vault is unsealed and answers this machine"
else
  bad_ "Vault is unsealed and answers this machine"
fi
if smoke_play enclave.yml; then ok "no other VM reaches Vault or Vaultwarden"; else bad_ "no other VM reaches Vault or Vaultwarden"; fi
done_ enclave
