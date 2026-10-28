# anvil

[![ci](https://img.shields.io/github/actions/workflow/status/memetics19/anvil/ci.yml?branch=main&event=push&label=ci)](https://github.com/memetics19/anvil/actions/workflows/ci.yml?query=branch%3Amain)
[![security](https://img.shields.io/github/actions/workflow/status/memetics19/anvil/security.yml?branch=main&label=trivy)](https://github.com/memetics19/anvil/actions/workflows/security.yml?query=branch%3Amain)
[![release](https://img.shields.io/github/v/release/memetics19/anvil)](https://github.com/memetics19/anvil/releases/latest)
[![go](https://img.shields.io/github/go-mod/go-version/memetics19/anvil?filename=cli%2Fgo.mod)](https://github.com/memetics19/anvil/blob/main/cli/go.mod)
[![license](https://img.shields.io/github/license/memetics19/anvil)](LICENSE)

Terraform, Ansible and a Go CLI for a Proxmox homelab. Every host is built from this repo.
A broken host is rebuilt from it, not fixed by hand.

![anvil installed with the one-line installer, then anvil version, anvil --help, anvil media --help and anvil services --help](docs/assets/anvil.gif)

## Contents

- [What anvil is](#what-anvil-is)
- [Why the name](#why-the-name)
- [What it sets up](#what-it-sets-up)
- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Make targets](#make-targets)
- [Configuration](#configuration)
- [Documentation](#documentation)
- [Repository layout](#repository-layout)
- [Roadmap](#roadmap)
- [Known issues](#known-issues)
- [Contributing](#contributing)
- [License](#license)

## What anvil is

anvil builds and runs a homelab from code. One repository holds the whole lab:

- **Terraform** creates the virtual machines on Proxmox VE.
- **Ansible** configures the hosts and every service on them.
- **The `anvil` CLI** wraps both. It checks first, shows what would change, asks, and then
  applies. It also installs Proxmox on a new server from bare metal, rotates API keys and
  checks every night that the lab still matches the code.
- **Vault** holds the secrets and the site values: addresses, names, logins. The repository
  is public and holds none of them.

A new server goes from bare metal to a running Proxmox host with anvil commands. A host
that breaks is rebuilt from the repository, not repaired by hand. It runs a real lab, two
Dell servers and a Cisco switch, and anyone can reuse it with their own site values.

## Why the name

A blacksmith shapes metal on an anvil. The anvil itself does not change: the same block
shapes piece after piece, and a piece that cracks goes back on it and is shaped again.

This repository is that block for the lab. Hosts and services are shaped on it. When one
breaks, it is rebuilt from the same code, the same way every time.

## What it sets up

- Terraform ([bpg/proxmox](https://github.com/bpg/terraform-provider-proxmox)) defines the
  VMs and the SDN.
- Ansible configures the Proxmox host and the guests.
- HashiCorp Vault holds the secrets and the site values.
- Terraform state lives in an S3 bucket on a single-node Ceph cluster on the same host.
- The `anvil` CLI runs the make targets: the whole lab, one service, checks, backups and
  restores.

It is a work in progress. See the [Roadmap](#roadmap).

### Hosts

| Host | Runs |
|---|---|
| `pve` | Proxmox VE 8.4, LAN gateway and NAT, NetBird, Ceph |
| `frigate` | Frigate, Mosquitto, Gotify, nginx, Docmost, cloudflared |
| `netbird` | NetBird routing peers (cloud and self-hosted), the self-hosted NetBird server, Redis, ntfy, Pulse, the apt repository, cloudflared |
| `ragnarok` | ARR stack, IPTV and its guide server, Filestash, cloudflared |
| `vault` | HashiCorp Vault, in the secrets enclave (no internet) |
| `vaultwarden` | Vaultwarden, in the secrets enclave (no internet, one mail hole) |
| `apps` | Pi-hole and Unbound, the Caddy service gateway, Homepage |

[docs/services.md](docs/services.md) describes each one.

### Hardware

| | `pve`, runs the lab | `pve2`, backups and new work (being installed) |
|---|---|---|
| Server | Dell PowerEdge T130 tower | Dell PowerEdge R620, 1U |
| CPU | Xeon E3-1220 v6, 4 cores | 2 × Xeon E5-2640 v2, 16 cores, 32 threads |
| RAM | 32 GB DDR4 ECC | 128 GB DDR3 ECC |
| Disks | 4 TB + 1 TB (Ceph OSD) | 4 × 1 TB + 4 × 2 TB, ZFS: mirror, mirror, RAIDZ1 |
| Network | 2 × 1 GbE | 2 × 10 GbE + 2 × 1 GbE |
| Out-of-band | iDRAC8 | iDRAC7 |

Switch: Cisco SG300-52, managed as code. Details, disk layout and limits:
[docs/hardware.md](docs/hardware.md).

## Install

`anvil` is one binary for macOS and Linux, amd64 or arm64.
[docs/install.md](docs/install.md) has every method and how to verify a download.

One command:

```sh
curl -fsSL https://memetics19.github.io/anvil/install.sh | sh
```

It installs to `/usr/local/bin`, or `~/.local/bin` when `/usr/local/bin` is not writable.
`ANVIL_VERSION` and `ANVIL_INSTALL_DIR` pick the version and the directory.

Homebrew:

```sh
brew tap memetics19/anvil https://github.com/memetics19/anvil
brew install anvil
```

Debian and Ubuntu, from the signed apt repository at `apt.shreeda.xyz`:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://apt.shreeda.xyz/anvil.gpg | sudo tee /etc/apt/keyrings/anvil.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/anvil.gpg] https://apt.shreeda.xyz stable main" |
  sudo tee /etc/apt/sources.list.d/anvil.list
sudo apt update && sudo apt install anvil
```

Fedora and RHEL, with the .rpm from [Releases](https://github.com/memetics19/anvil/releases):

```sh
sudo dnf install ./anvil-<version>-1.x86_64.rpm   # or .aarch64.rpm
```

From source, with Go:

```sh
git clone https://github.com/memetics19/anvil && cd anvil
make cli                                  # builds build/anvil
sudo install -m 755 build/anvil /usr/local/bin/anvil
```

## Quick start

You need a Mac, because the scripts keep secrets in its Keychain, and a Proxmox VE host.
Install the tools in [docs/setup.md](docs/setup.md#operator-machine), and add the Keychain
items and the site dict it describes. Then:

```sh
anvil fetch    # clones this repo into ~/.local/share/anvil/repo
anvil doctor   # checks tools, Keychain items and Vault, read-only, with a fix for each problem
anvil up       # builds the whole lab, in the order of the first build
```

`anvil up` runs the steps of [First build](docs/setup.md#first-build) as stages. Each
stage runs its check first and applies only what differs. On a running lab it is a
converge, and a host that matches the code reports `changed=0`.

## Commands

| Command | What it does |
|---|---|
| `anvil up [service ...]` | Build or converge the whole lab, or deploy named services |
| `anvil doctor`, `anvil init` | Check the tools, the Keychain items and Vault, read-only. `doctor --fix` removes Mac routes that hide the VPN |
| `anvil status` | A read-only dashboard of the lab |
| `anvil check <target>` | Dry run a target: `--check --diff`, `tf-plan` or the switch plan |
| `anvil apply <target>` | Check a target, then apply it after confirmation |
| `anvil drift` | The nightly check. Pushes to ntfy when the lab drifted. `--install` schedules it |
| `anvil services` | List the services, VMs and lab targets that `check`, `apply` and `up` accept |
| `anvil backup` | Run `make backup` |
| `anvil restore <part>` | The documented restore steps, with confirmation |
| `anvil provision-iso <name>` | Build the Proxmox auto-install ISO for a new server |
| `anvil provision <name>` | Install Proxmox on a new server, a dry run unless `--install` |
| `anvil pools <name>` | Create the ZFS data pools of a newly installed server |
| `anvil increase-disk <vm> <size>` | Grow a VM's disk while it runs |
| `anvil rotate <secret>` | New API keys for Radarr, Sonarr or Prowlarr, and everything that uses them |
| `anvil media <command>` | Search, download and follow movies and series (Radarr, Sonarr) |
| `anvil fetch`, `anvil update` | Clone the repo for a packaged install, or move it to this binary's version |
| `anvil version` | Print the version, commit, build date, Go version and platform |
| `anvil completion <shell>` | Print a bash, zsh or fish completion script |

Every command takes `--help`, `--no-color` and, where it runs make, `--dry-run`.
[docs/cli.md](docs/cli.md) describes each one.

## Make targets

`anvil` runs these make targets. They also work on their own. These two need no secrets:

```sh
make lint secrets-scan
```

Most work is a dry run, then the real run:

```sh
make vm HOST=apps ARGS="--check --diff"
make vm HOST=apps
make tf-plan
make tf-apply
make backup
```

[docs/usage.md](docs/usage.md) lists every target.

## Configuration

- The `site` dict holds the addresses, MACs, VM IDs and the domain. Its canonical copy is
  in Vault at `kv/homelab/site`.
- Before Vault exists, the scripts read a bootstrap copy from the Keychain item
  `site-bootstrap`.
- [`site/site.example.yml`](site/site.example.yml) shows the structure.
- Secrets are in Vault under `kv/homelab/<host>/<app>`. [docs/secrets.md](docs/secrets.md)
  lists them.

## Documentation

The docs site is <https://memetics19.github.io/anvil/>. `make docs` builds it locally.
`make docs-publish` also serves it privately on the gateway as
`https://docs.<gateway-domain>` ([usage](docs/usage.md#publishing-the-docs)).

| Page | Covers |
|---|---|
| [install.md](docs/install.md) | Installing `anvil`, and how releases are cut |
| [setup.md](docs/setup.md) | The operator Mac, Keychain items, the site dict, the first build, rebuilding on a new box, the hand steps |
| [usage.md](docs/usage.md) | Make targets, adding a service, secrets, backups, safety rails, upgrades, tests, troubleshooting |
| [cli.md](docs/cli.md) | Every `anvil` command |
| [provisioning.md](docs/provisioning.md) | Installing Proxmox VE on a new server with the automated installer ISO, Redfish or IPMI |
| [hardware.md](docs/hardware.md) | The two servers and the switch: models, disk layout, roles and limits |
| [services.md](docs/services.md) | What each host and role does |
| [secrets.md](docs/secrets.md) | Every Vault path and key |
| [cisco-switch.md](docs/cisco-switch.md) | The Cisco switch: what `make switch` manages and what is set by hand |

## Repository layout

```
ansible/
  inventory/      hosts by name, group_vars/all/site.yml resolves `site`
  playbooks/
  roles/
cli/              the anvil CLI (Go), make cli builds build/anvil
docs/             the docs site pages, docs/assets/ holds the demo GIF and its VHS tape
Formula/          the Homebrew formula, updated by each release
iptv/             the IPTV channel list
packaging/        the .deb and .rpm post-install script
scripts/          env.sh, plan-guard.sh, the installer, backup and Keychain helpers
site/             site.example.yml
terraform/        VMs, SDN, import blocks
tests/            shell tests, run by CI
vault/policies/   Vault policies
```

To re-record the demo GIF, run from the repo root:

```sh
docker run --rm -v "$PWD":/vhs ghcr.io/charmbracelet/vhs docs/assets/anvil.tape
```

## Roadmap

Done:

- [x] Secret scanning, linters, CI
- [x] Trivy on every pull request and weekly. The repository and the release binary block on
  a fixable HIGH or CRITICAL finding. Every pinned container image is reported.
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
- [x] VLANs 10/20/30 with routing, DHCP, NTP and an inter-VLAN firewall. The switch and a
  VLAN-capable access point are hand steps.
- [x] Bare-metal provisioning: Proxmox auto-install ISO, delivered by Redfish, IPMI or PXE,
  brand agnostic ([docs/provisioning.md](docs/provisioning.md)). Tested end to end on VMs.
  The first real server is the next one.
- [x] Releases: semver tags and a changelog from conventional commits (release-please),
  published as GitHub Releases, starting with v0.1.0
- [x] An `anvil` CLI over the make targets ([docs/cli.md](docs/cli.md)). A fresh box run is
  still untested.
- [x] Packages: .deb and .rpm built with nfpm, a Homebrew formula and a one-line installer,
  from GoReleaser on each release, with this repo as the Homebrew tap
  ([docs/install.md](docs/install.md))
- [x] A signed apt repository for the .deb, `apt.shreeda.xyz`, published by the homelab
  from each release ([docs/install.md](docs/install.md#debian-and-ubuntu))
- [x] cloudflared pinned: one `cloudflared_version`, installed from Cloudflare's apt
  repository and held. Upgrades go one connector at a time while the others keep the
  tunnel up. The token is read from a root-only file, not the process list.

Planned:

- [ ] Monitoring: VictoriaMetrics, Grafana, exporters, alerts to ntfy
- [ ] Patch tracking: [PatchMon](https://github.com/PatchMon/PatchMon) for pending and
  security updates on every host (on the second server)
- [ ] Single sign-on (Authelia) in front of the gateway
- [ ] Self-hosted NetBird next to the hosted one. The server and dashboard run. The routing
  peer waits for a route that passes gRPC, which the Cloudflare tunnel does not.
- [ ] Split the generic core (roles, Terraform modules, scripts) from this lab's site
  layer, so it works on another Proxmox box
- [ ] OS agnostic operator machine: Linux, macOS or Windows (WSL). Secrets move from the
  macOS Keychain to a pluggable backend (Vault plus an age-encrypted bootstrap file, the
  Linux secret service, or the macOS Keychain). The scripts drop macOS-only commands
  (`security`, `networksetup`, `pbcopy`, BSD `sed` and `stat`).
- [ ] The rebuild runbook, tested on a second server

## Known issues

- Frigate's camera has not answered since 2026-01-13, so there are no new recordings.
- Frigate's `genai` provider points at an Ollama address that does not answer.
- `/home` on `ragnarok` is 98% full.
- The Ceph dashboard's Object Gateway zone and multisite pages return 500 on Proxmox. See
  [Ceph](docs/services.md#ceph).

## Contributing

Issues and pull requests are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the checks to
run, the commit style, and how pull requests are merged and stacked.

## License

[MIT](LICENSE)
