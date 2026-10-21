# Ansible reads homelab secrets (KV v2 at kv/, paths kv/homelab/<host>/<app>). Read only.
path "kv/data/homelab/*" {
  capabilities = ["read"]
}
