# Changelog

## [0.1.0](https://github.com/memetics19/anvil/releases/tag/v0.1.0) (2026-10-22)

The first release. Everything before it is in the git history.

### The anvil CLI

* `anvil up` builds the whole lab in the order of the first build, as stages. It checks
  each stage first, asks once, can resume with `--from`, and can run named services only.
* `anvil check`, `anvil apply`, `anvil status`, `anvil services`, `anvil backup` and
  `anvil restore` over the make targets.
* `anvil doctor` checks the tools, Keychain items, Vault and versions, read-only, with a
  fix for each problem. `anvil init` is the same check for a new machine.
* `anvil fetch` and `anvil update` keep a copy of the repo for a packaged install.
* `anvil provision` installs Proxmox VE on a new server, a dry run by default.
* Terraform init and the Ansible collections are set up on the first run.
* Completions for bash, zsh and fish.

### Install

* One command: `curl -fsSL https://memetics19.github.io/anvil/install.sh | sh`
* Homebrew from this repo, .deb and .rpm packages, and archives for macOS and Linux on
  amd64 and arm64, each in `checksums.txt`.

### The lab

* Proxmox host, VMs, Ceph for the Terraform state, Vault, Vaultwarden, the gateway with
  private names and certificates, Pi-hole, Homepage, NetBird cloud and self-hosted, VLANs,
  the Cisco switch, IPTV and the media stack, all from the site dict in Vault.
* Bare-metal provisioning with the Proxmox automated installer, over Redfish, IPMI or PXE.
