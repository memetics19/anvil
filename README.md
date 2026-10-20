# anvil

Infrastructure as code for a single-node Proxmox homelab. The goal is simple: if the
box dies, a fresh Proxmox install plus this repo gets every VM and service back the way
it was, and the running box is changed only through this repo.

- **Terraform** (`bpg/proxmox`) owns the VM definitions.
- **Ansible** configures the Proxmox host and everything inside the VMs.
- **HashiCorp Vault** holds every secret and every site-specific value.
- **Ceph** (single node, S3 via RADOS Gateway) stores the Terraform state.

> **Status: work in progress.** The guardrails, the Ansible inventory and the Proxmox
> host base role are done and running against the real box. Everything else is in the
> [roadmap](#roadmap).

## This repo has no secrets and no addresses

The repo is public, so nothing that identifies the site is committed. That means no IP
addresses, MAC addresses, domain, email, tokens, passwords or keys.

- Real values live in **Vault** at `kv/homelab/site`. Before Vault exists they live in the
  **macOS Keychain** (service `homelab`). They never sit in a plaintext file, and that
  includes gitignored files.
- Code refers to hosts by name only (`pve`, `frigate`, `netbird`, `ragnarok`, `vault`).
  Ansible resolves addresses from a single `site` dict (see
  [`site/site.example.yml`](site/site.example.yml), which uses RFC 5737 placeholders).
- [gitleaks](https://github.com/gitleaks/gitleaks) runs in pre-commit and in CI over the
  full history. On top of the default rules it rejects:
  - private IPv4 literals
  - Cloudflare tunnel tokens
  - NetBird setup keys
  - password hashes
  - literal passwords
- The guardrail test (`tests/test_secrets_scan.sh`) plants fake secrets at runtime and
  checks that every rule fires. It also checks that documentation ranges such as
  `192.0.2.0/24` don't trip the scan.

## What it manages

| Host | What runs there |
|---|---|
| `pve` | Proxmox VE 8.4. It acts as the LAN gateway, NATing guests out to the home router. It also runs NetBird, chrony and single-node Ceph. |
| `frigate` | Frigate NVR, Mosquitto, frigate-notify, Gotify, nginx, cloudflared |
| `netbird` | NetBird routing peer, Redis, ntfy, pulse (Caddy), cloudflared |
| `ragnarok` | Media automation (qBittorrent, Prowlarr, Jackett, FlareSolverr, Radarr, Sonarr), an IPTV EPG server, an MCP server, cloudflared |
| `vault` | HashiCorp Vault (Raft storage, KV v2). New. |

The media library on `ragnarok` is the only data that matters. Its disk is protected
with `prevent_destroy`, and no Ansible task touches the media path. Everything else is
treated as stateless and can be rebuilt empty.

## Layout

```
ansible/
  inventory/            hosts by name; group_vars/all/site.yml resolves the site dict
  playbooks/            bootstrap-ssh.yml, host.yml
  roles/pve_host/       apt sources, packages, chrony, /etc/hosts, Terraform API token
scripts/
  env.sh                exports endpoints and tokens from Keychain (never prints values)
  plan-guard.sh         refuses Terraform plans that delete or replace VMs (WIP)
site/site.example.yml   structure of the site dict, with placeholder values
tests/                  guardrail tests
.gitleaks.toml          secret and private-IP rules
```

## Requirements

On the operator's Mac:

```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform hashicorp/tap/vault ansible ansible-lint \
  gitleaks tflint yamllint jq pre-commit sshpass awscli
ansible-galaxy collection install -r ansible/requirements.yml -p ~/.ansible/collections
pre-commit install
```

Terraform 1.10 or newer is needed (the S3 backend uses `use_lockfile`).

### Keychain items

All items use service `homelab`. Read them with
`security find-generic-password -s homelab -a <account> -w`.

| Account | Holds |
|---|---|
| `pve-ip`, `vault-ip` | the two addresses needed to reach Proxmox and Vault |
| `site-bootstrap` | the full `site` dict as YAML, until it moves into Vault |
| `pve-root-password`, `vm-sudo-password` | used once by `bootstrap-ssh`, then as the become password |
| `pve-api-token` | Terraform's Proxmox API token, written by the `pve_host` role |
| `ceph-s3-access-key`, `ceph-s3-secret-key` | Terraform state backend *(roadmap)* |
| `vault-init-json` | Vault unseal keys and root token *(roadmap)* |

## Usage

Every `make` target sources `scripts/env.sh` first.

```bash
make lint            # terraform fmt/tflint, yamllint, ansible-lint
make secrets-scan    # gitleaks over git history and tracked files
make bootstrap-ssh   # once: installs your SSH key on the host and guests
make host            # configure the Proxmox host
make host ARGS="--check --diff"   # dry run against the live box
```

Changes to the live box are always dry-run first. A run is expected to report
`changed=0` on a box that already matches the code.

## Hand-managed things

These are deliberately not in code. Only their tokens go into Vault.

- Cloudflare tunnels and their public hostnames.
- NetBird routes, access rules and setup keys (NetBird dashboard).
- A DHCP reservation on the home router for the Proxmox uplink address.
- After a rebuild, app state that lives in databases has to be set up again by hand:
  - media-automation indexers, API keys and download clients
  - Frigate's database and recordings
  - ntfy users

## Roadmap

- [x] Guardrails: secret scanning, private-IP rule, linters, CI
- [x] Ansible inventory, SSH bootstrap, Proxmox host base role (dry-run clean on the live box)
- [ ] Host network as code, with automatic rollback if the host stops answering
- [ ] Single-node Ceph with RADOS Gateway, plus a bucket for Terraform state
- [ ] Terraform: Proxmox provider and Ceph S3 backend
- [ ] Terraform: adopt the existing VMs and SDN unchanged, with a plan guard against destroys
- [ ] Vault VM, Keychain-held unseal keys, snapshot backups to the Mac
- [ ] Move all secrets and site values from Keychain and the VMs into Vault
- [ ] Shared guest roles: network, Docker, node_exporter, cloudflared
- [ ] Workload roles for `frigate`, `ragnarok` and `netbird`
- [ ] A full new-box runbook, tested on a second server

## Known issues on the live box

These are recorded as found. Fixing them is separate work.

- `frigate-notify` crash-loops.
- `dispatcharr` exits on start.
- `privoxy` reports unhealthy.
- The nginx upstream on `frigate` points at a stale address.
- `ragnarok`'s `/home` is 98% full.
- Guest netplan files carry a historical name (`60-opnsense.yaml`).
- The SDN VLANs 10/20/30 and `vmbr1` are defined but unused.

## License

[MIT](LICENSE)
