# Changelog

## [0.3.0](https://github.com/memetics19/anvil/compare/v0.2.0...v0.3.0) (2026-10-22)


### Features

* **apt_repo:** a signed apt repository for the anvil .deb packages ([b50f489](https://github.com/memetics19/anvil/commit/b50f48997b4a519a94d22d3169b644ecee5ec099))
* **apt_repo:** a signed apt repository for the anvil .deb packages, on the netbird VM ([553c5ec](https://github.com/memetics19/anvil/commit/553c5ec36f3deea904b03f976c84aaa817dbe590))


### Bug Fixes

* **apt_repo:** a fresh tree directory per build, even within one second ([3ab58d1](https://github.com/memetics19/anvil/commit/3ab58d1265d5e94c6cf5903d94895d08a3901ba1))
* **apt_repo:** compose_project writes the compose file, so a dry run works on a new host ([e77e80f](https://github.com/memetics19/anvil/commit/e77e80fba9c85fb408f6fa0a5446fd44f1449afd))
* **cli:** build with Go 1.27.3 (CVE-2026-111943, crypto/x509) ([e4c19c7](https://github.com/memetics19/anvil/commit/e4c19c73641387c2ee61e80a3d2c73b1300e3989))
* **pulse:** the first pulse-update run works before release.env exists ([49598b9](https://github.com/memetics19/anvil/commit/49598b9ec5611f72d0c05c0e99e7374437523dc7))
* **pulse:** the first pulse-update run works before release.env exists ([483eeb1](https://github.com/memetics19/anvil/commit/483eeb14eb06a9242d17479b8e23276fa13e69f5))

## [0.2.0](https://github.com/memetics19/anvil/compare/v0.1.0...v0.2.0) (2026-10-22)


### Features

* **pulse:** the VM deploys each Pulse release and the docs from main by itself ([59be7b5](https://github.com/memetics19/anvil/commit/59be7b53af20586b3a276163df82d5d5787e24ae))
* **pulse:** the VM deploys each Pulse release and the docs from main by itself ([d8dba0f](https://github.com/memetics19/anvil/commit/d8dba0fcc47cd5eabfbd544683e24f522191ef89))


### Bug Fixes

* **pulse:** install pulse-update from its .sh template ([d57dd71](https://github.com/memetics19/anvil/commit/d57dd71218740eb43c569a24b2e4311bd037ae35))

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
