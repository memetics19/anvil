# anvil

[![ci](https://github.com/memetics19/anvil/actions/workflows/ci.yml/badge.svg)](https://github.com/memetics19/anvil/actions/workflows/ci.yml)

Terraform and Ansible for a single-node Proxmox homelab.

- Terraform ([bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox)) defines the VMs.
- Ansible configures the Proxmox host and the guests.
- Secrets and site-specific values come from HashiCorp Vault.
- Terraform state lives in a single-node Ceph cluster, using its S3 gateway.

Work in progress. See [Roadmap](#roadmap).

## Hosts

| Host       | Role                                                          |
|------------|---------------------------------------------------------------|
| `pve`      | Proxmox VE 8.4, LAN gateway/NAT, NetBird, Ceph                |
| `frigate`  | Frigate, Mosquitto, Gotify, nginx, cloudflared                |
| `netbird`  | NetBird routing peer, Redis, ntfy, pulse, cloudflared         |
| `ragnarok` | qBittorrent, Prowlarr, Jackett, Radarr, Sonarr, cloudflared   |
| `vault`    | HashiCorp Vault (planned)                                     |

## Requirements

- macOS operator machine (uses the Keychain)
- Terraform >= 1.10
- Ansible, ansible-lint, yamllint, tflint, gitleaks, sshpass

```sh
brew tap hashicorp/tap
brew install hashicorp/tap/terraform hashicorp/tap/vault ansible ansible-lint \
  gitleaks tflint yamllint jq pre-commit sshpass awscli
ansible-galaxy collection install -r ansible/requirements.yml -p ~/.ansible/collections
pre-commit install
```

## Configuration

Nothing site-specific is committed: no addresses, MACs, domain, credentials or VM IDs.
Code refers to hosts by name only. Ansible reads one `site` dict, with the following
precedence:

1. Vault, `kv/homelab/site`, when `VAULT_TOKEN` is set
2. macOS Keychain, service `homelab`, account `site-bootstrap`

[`site/site.example.yml`](site/site.example.yml) documents the structure.

Keychain accounts (service `homelab`):

| Account                                    | Used for                        |
|--------------------------------------------|---------------------------------|
| `pve-ip`, `vault-ip`                       | reaching Proxmox and Vault      |
| `site-bootstrap`                           | `site` dict before Vault exists |
| `pve-root-password`, `vm-sudo-password`    | SSH bootstrap, become password  |
| `pve-api-token`                            | Terraform provider              |
| `ceph-s3-access-key`, `ceph-s3-secret-key` | Terraform state (planned)       |
| `vault-init-json`                          | unseal keys (planned)           |

## Usage

```sh
make bootstrap-ssh                # once: install your SSH key on all hosts
make host ARGS="--check --diff"   # dry run against the Proxmox host
make host
make lint
make secrets-scan
```

Infrastructure targets source `scripts/env.sh`, which loads endpoints and tokens from
the Keychain. Dry-run first. A box that matches the code reports `changed=0`.

## Layout

```
ansible/
  inventory/      hosts by name; group_vars/all/site.yml resolves `site`
  playbooks/
  roles/
scripts/          env.sh, plan-guard.sh
site/             site.example.yml
tests/
```

## Secret scanning

[gitleaks](https://github.com/gitleaks/gitleaks) runs in pre-commit and in CI, over the full
history. [`.gitleaks.toml`](.gitleaks.toml) adds rules for:

- private IPv4 addresses
- Cloudflare tunnel tokens
- NetBird setup keys
- password hashes and literal passwords

`tests/test_secrets_scan.sh` checks that each rule fires on generated fixtures.

## Not managed here

- Cloudflare tunnels and public hostnames
- NetBird routes, ACLs and setup keys
- DHCP reservation for the Proxmox uplink on the home router
- App state kept in databases (indexers, API keys, Frigate recordings), which is
  reconfigured by hand after a rebuild

## Roadmap

- [x] Secret scanning, linters, CI
- [x] Inventory, SSH bootstrap, Proxmox host base role
- [ ] Host network, with automatic rollback
- [ ] SDN VLANs and inter-VLAN firewall
- [ ] Single-node Ceph and S3 gateway for Terraform state
- [ ] Terraform: adopt existing VMs and SDN, guard against destroys
- [ ] Vault VM, Keychain-held unseal keys, snapshot backups
- [ ] Move secrets and site values into Vault
- [ ] Guest roles: base, Docker, node_exporter, cloudflared
- [ ] Workload roles for `frigate`, `ragnarok`, `netbird`
- [ ] Rebuild runbook, tested on a second server

## Known issues

- `frigate-notify` crash-loops
- `dispatcharr` exits on start
- `privoxy` reports unhealthy
- nginx on `frigate` proxies to a stale upstream
- `ragnarok` `/home` is 98% full

## License

[MIT](LICENSE)
