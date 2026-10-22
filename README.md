# anvil

[![ci](https://github.com/memetics19/anvil/actions/workflows/ci.yml/badge.svg?branch=main&event=push)](https://github.com/memetics19/anvil/actions/workflows/ci.yml?query=branch%3Amain)

Terraform and Ansible for a single-node Proxmox homelab.

A smith shapes everything else on the anvil. Every host in the lab is built from this
repo, and a broken one gets rebuilt from it instead of fixed by hand.

Terraform ([bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox)) defines the
VMs, Ansible configures the Proxmox host and the guests, and HashiCorp Vault holds the
secrets and site values. Terraform state lives in an S3 bucket on a single-node Ceph
cluster on the same host.

It is a work in progress. See the [Roadmap](#roadmap).

## Hardware


- Dell PowerEdge T130 tower server:
  - CPU: `Intel Xeon E3-1220 v6 @ 3.00GHz` (4 cores, 4 threads)
  - RAM: `32GB` DDR4-2400 ECC (4 × 8GB)
  - RAID controller: `PERC H730` (each disk is its own virtual disk)
  - Disks: `4TB` Seagate Exos 7200 rpm (Proxmox, VM disks, media) and `1TB` Seagate Exos 7200 rpm (Ceph OSD)
  - Network: 2 × `1GbE` (Broadcom BCM5720)
  - Out-of-band: iDRAC8
- Cisco managed switch

## Hosts

| Host       | Runs |
|------------|------|
| `pve`      | Proxmox VE 8.4, LAN gateway and NAT, NetBird, Ceph |
| `frigate`  | Frigate, Mosquitto, Gotify, nginx, cloudflared |
| `netbird`  | NetBird routing peers (cloud and self-hosted), the self-hosted NetBird server, Redis, ntfy, Pulse, cloudflared |
| `ragnarok` | ARR stack, IPTV, Filestash, cloudflared |
| `vault`    | HashiCorp Vault, in the secrets enclave (no internet) |
| `vaultwarden` | Vaultwarden, in the secrets enclave (no internet, one mail hole) |
| `apps`     | Pi-hole and Unbound, the Caddy service gateway, Homepage |

[docs/services.md](docs/services.md) describes what runs on each one.

## Quick start

You need a Mac, because the scripts keep secrets in its Keychain, and a Proxmox VE host.
Install the tools listed in [docs/setup.md](docs/setup.md#operator-machine), and add the
Keychain items and the site dict it describes. Then:

```sh
curl -fsSL https://memetics19.github.io/anvil/install.sh | sh   # installs anvil from the latest release
anvil fetch   # clones this repo into ~/.local/share/anvil/repo
anvil doctor  # tools, Keychain items and Vault, read-only, with a fix for each problem
anvil up      # the whole lab, in the order of the first build
```

Homebrew, a .deb or .rpm from [Releases](https://github.com/memetics19/anvil/releases),
and `make cli` in a checkout work too. [docs/install.md](docs/install.md) has every way.

`anvil up` runs the steps of [First build](docs/setup.md#first-build) as stages. It checks
each stage first and applies only what differs, so on a running lab it is a converge. A host that matches the code reports `changed=0`. One service at a time is
`anvil up pihole`. [docs/cli.md](docs/cli.md) describes every command.

The make targets underneath work on their own too. These two need no secrets:

```sh
make lint secrets-scan
```

Most work is a dry run followed by the real run:

```sh
make vm HOST=apps ARGS="--check --diff"
make vm HOST=apps
make tf-plan
make tf-apply
make backup
```

## Configuration

Addresses, MACs, VM IDs and the domain live in one `site` dict. Its canonical copy is in
Vault at `kv/homelab/site`. Before Vault exists, the scripts read a bootstrap copy from the
Keychain item `site-bootstrap`. [`site/site.example.yml`](site/site.example.yml) shows the
structure. Secrets are in Vault under `kv/homelab/<host>/<app>`, listed in
[docs/secrets.md](docs/secrets.md).

## Documentation

The docs are also published as a site: <https://memetics19.github.io/anvil/>. Build it
locally with `make docs`. `make docs-publish` also serves it privately on the gateway as
`https://docs.<gateway-domain>` ([usage](docs/usage.md#publishing-the-docs)).

- [docs/install.md](docs/install.md): installing `anvil` with one command, Homebrew, a
  .deb or .rpm, or from source, and how releases are cut
- [docs/setup.md](docs/setup.md): the operator Mac, Keychain items, the site dict, the
  first build, rebuilding on a new box, and the hand steps
- [docs/usage.md](docs/usage.md): make targets, adding a service, secrets, backups, safety
  rails, upgrades, tests, troubleshooting
- [docs/cli.md](docs/cli.md): the `anvil` CLI, from `anvil up` for the whole lab to one
  service, check, apply, status and restore
- [docs/provisioning.md](docs/provisioning.md): installing Proxmox VE on a new server with
  the automated installer ISO, Redfish or IPMI
- [docs/services.md](docs/services.md): what each host and role does
- [docs/secrets.md](docs/secrets.md): every Vault path and key

## Layout

```
ansible/
  inventory/      hosts by name; group_vars/all/site.yml resolves `site`
  playbooks/
  roles/
cli/              the anvil CLI (Go), make cli builds build/anvil
scripts/          env.sh, plan-guard.sh, backup and Keychain helpers
site/             site.example.yml
terraform/        VMs, SDN, import blocks
tests/
vault/policies/
```

## Roadmap

- [x] Secret scanning, linters, CI
- [x] Inventory, SSH bootstrap, Proxmox host base role
- [x] Host network with automatic rollback
- [x] Single-node Ceph and S3 gateway for Terraform state
- [x] Terraform: adopt the existing VMs and SDN, guard against destroys
- [x] Vault VM, Keychain-held unseal keys, snapshot backups
- [x] Secrets and site values in Vault
- [x] Guest roles: base, Docker, node_exporter, cloudflared
- [x] Workload roles for `frigate`, `ragnarok` and `netbird`
- [x] Private service gateway (Caddy, wildcard DNS-01, Pi-hole records)
- [x] Pi-hole and Unbound for the home network
- [x] Homepage dashboard
- [x] Vaultwarden with encrypted backups and a restore drill
- [x] Secrets enclave: Vault and Vaultwarden on an isolated network, reachable only from
  the operator's devices, firewalled by data-driven routed segments
- [x] VLANs 10/20/30 with routing, DHCP, NTP and an inter-VLAN firewall (the switch and a
  VLAN-capable access point are hand steps)
- [ ] Monitoring: VictoriaMetrics, Grafana, exporters, alerts to ntfy
- [ ] Patch tracking: [PatchMon](https://github.com/PatchMon/PatchMon) for pending and security
  updates on every host (on the second server)
- [ ] Single sign-on (Authelia) in front of the gateway
- [ ] Self-hosted NetBird next to the hosted one (the server and dashboard run. The
  routing peer waits for a route that passes gRPC, which the Cloudflare tunnel does not)
- [x] Bare-metal provisioning: Proxmox auto-install ISO, delivered by Redfish, IPMI or PXE,
  brand agnostic ([docs/provisioning.md](docs/provisioning.md). Tested end to end on VMs,
  the first real server is the next one)
- [x] Releases: semver tags and a changelog from conventional commits (release-please),
  published as GitHub Releases, starting with v0.1.0
- [ ] Split the generic core (roles, Terraform modules, scripts) from this lab's site
  layer, so it works on another Proxmox box
- [x] An `anvil` CLI over the make targets: `anvil up` for the whole lab or one service,
  doctor, status, check, apply, backup, restore, fetch, update and shell completion
  ([docs/cli.md](docs/cli.md). A fresh box run is still untested)
- [ ] OS agnostic operator machine: run from Linux, macOS or Windows (WSL), not only a Mac.
  Secrets move from the macOS Keychain to a pluggable backend (Vault plus an age-encrypted
  bootstrap file, the Linux secret service, or the macOS Keychain), and the scripts drop
  macOS-only commands (`security`, `networksetup`, `pbcopy`, BSD `sed` and `stat`)
- [x] Packages: .deb and .rpm built with nfpm, a Homebrew formula and a one-line
  installer, from GoReleaser on each release, with this repo as the Homebrew tap
  ([docs/install.md](docs/install.md))
- [ ] A signed apt repository for the .deb
- [ ] The rebuild runbook, tested on a second server

## Known issues

- Frigate's camera has not answered since 2026-01-13, so there are no new recordings.
- Frigate's `genai` provider points at an Ollama address that does not answer.
- `/home` on `ragnarok` is 98% full.
- The Ceph dashboard's Object Gateway zone and multisite pages return 500 on Proxmox. See
  [Ceph](docs/services.md#ceph).

## License

[MIT](LICENSE)
