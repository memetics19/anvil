# Changelog

## [0.13.2](https://github.com/memetics19/anvil/compare/v0.13.1...v0.13.2) (2026-10-28)


### Bug Fixes

* VMs keep their SSH host keys after a host reboot ([#121](https://github.com/memetics19/anvil/issues/121)) ([01a5f2f](https://github.com/memetics19/anvil/commit/01a5f2f02539e61f245ff8c247255047c0e267d6))

## [0.13.1](https://github.com/memetics19/anvil/compare/v0.13.0...v0.13.1) (2026-10-28)


### Bug Fixes

* **terraform:** refuse a two-NIC VM whose NICs share one MAC ([#118](https://github.com/memetics19/anvil/issues/118)) ([da489da](https://github.com/memetics19/anvil/commit/da489da2085b04c76d0885d929d3c2b323d093a3))

## [0.13.0](https://github.com/memetics19/anvil/compare/v0.12.0...v0.13.0) (2026-10-28)


### Features

* **authentik:** nightly encrypted backups of the Authentik database ([#114](https://github.com/memetics19/anvil/issues/114)) ([49eb517](https://github.com/memetics19/anvil/commit/49eb517e7bc1cec0f954488943a8fa844dd6f413))
* **authentik:** nightly encrypted backups of the Authentik database ([#116](https://github.com/memetics19/anvil/issues/116)) ([c73efff](https://github.com/memetics19/anvil/commit/c73efff21200c5222df40be2f9fa5cdb4f356a4e))

## [0.12.0](https://github.com/memetics19/anvil/compare/v0.11.0...v0.12.0) (2026-10-28)


### Features

* **authentik:** single sign-on on the identity VM ([#111](https://github.com/memetics19/anvil/issues/111)) ([77a18c3](https://github.com/memetics19/anvil/commit/77a18c3195e1e323aae0d0e84eb64b6641ad64d7))
* **terraform:** an identity VM on the second Proxmox node ([#108](https://github.com/memetics19/anvil/issues/108)) ([c8beabe](https://github.com/memetics19/anvil/commit/c8beabeef1ef6d523b348ffa7ca752f3a7b87ecd))

## [0.11.0](https://github.com/memetics19/anvil/compare/v0.10.2...v0.11.0) (2026-10-28)


### Features

* **frigate_stack:** build the camera stream URL from its address and login ([#105](https://github.com/memetics19/anvil/issues/105)) ([97e5c1f](https://github.com/memetics19/anvil/commit/97e5c1f83da8055e93da31b1019f76efbba7ec1b))

## [0.10.2](https://github.com/memetics19/anvil/compare/v0.10.1...v0.10.2) (2026-10-28)


### Bug Fixes

* **security:** bump Filestash to the 2026-10-28 build (1 fixable CVE) ([#101](https://github.com/memetics19/anvil/issues/101)) ([8c2eb8a](https://github.com/memetics19/anvil/commit/8c2eb8ad7f73d8f1e109193f1f899e704e205713))
* **security:** one code scanning category per image, fixable CVEs only ([#102](https://github.com/memetics19/anvil/issues/102)) ([0ae1048](https://github.com/memetics19/anvil/commit/0ae104886695ad0ab543184c18641e64ef982915))

## [0.10.1](https://github.com/memetics19/anvil/compare/v0.10.0...v0.10.1) (2026-10-28)


### Bug Fixes

* **security:** bump Docmost to 0.97.0 (163 fixable CVEs) ([#94](https://github.com/memetics19/anvil/issues/94)) ([2ec7f5e](https://github.com/memetics19/anvil/commit/2ec7f5e07adfe6e4316dcd5d69fd6cbd9bddcad0))
* **security:** bump Gotify to 3.1.1 (34 fixable CVEs) ([#92](https://github.com/memetics19/anvil/issues/92)) ([51f072a](https://github.com/memetics19/anvil/commit/51f072aa41516059b299a3a9c0f15346e579c25a))
* **security:** bump Homepage to v2.7.0 (11 fixable CVEs) ([#98](https://github.com/memetics19/anvil/issues/98)) ([90b5ac8](https://github.com/memetics19/anvil/commit/90b5ac8d97e6c03ed5b4296eb13c5224137844e1))
* **security:** bump mkdocs-material to 9.8.0 (158 fixable CVEs) ([#100](https://github.com/memetics19/anvil/issues/100)) ([5e125a9](https://github.com/memetics19/anvil/commit/5e125a9e2e07f88e101fa7f80eae1c706258023f))
* **security:** bump NetBird server to 0.81.5 and dashboard to v2.96.0 (80 fixable CVEs) ([#97](https://github.com/memetics19/anvil/issues/97)) ([0607fc2](https://github.com/memetics19/anvil/commit/0607fc249e20b8c6f845246d0abef4538ad3441a))
* **zfs_pools:** --wipe takes several pools, comma separated ([#93](https://github.com/memetics19/anvil/issues/93)) ([00212f6](https://github.com/memetics19/anvil/commit/00212f6a7e1a2e666c00ef2349518e19e55eb66e))

## [0.10.0](https://github.com/memetics19/anvil/compare/v0.9.0...v0.10.0) (2026-10-28)


### Features

* anvil apply cluster joins a provisioned server to the Proxmox cluster ([#85](https://github.com/memetics19/anvil/issues/85)) ([badb5ff](https://github.com/memetics19/anvil/commit/badb5ff37b0d2fcf57ceca7480f740c71c6b701d))
* **homepage,caddy:** pve2 on the gateway and the dashboard ([#86](https://github.com/memetics19/anvil/issues/86)) ([acd846e](https://github.com/memetics19/anvil/commit/acd846e5f9e035077c540520a3a6586011f66da6))


### Bug Fixes

* **docs:** the anvil picture on the docs site ([#90](https://github.com/memetics19/anvil/issues/90)) ([1ae2a28](https://github.com/memetics19/anvil/commit/1ae2a28527819f6153b94324307028b87b530a3a))
* **security:** bump eclipse-mosquitto to 2.0.22 (101 fixable CVEs) ([#84](https://github.com/memetics19/anvil/issues/84)) ([635b1e5](https://github.com/memetics19/anvil/commit/635b1e5243f05442e76e39e21f1e5bdf3b4a67c0))
* **security:** bump frigate-notify to v0.5.4 (19 fixable CVEs) ([#89](https://github.com/memetics19/anvil/issues/89)) ([bb62ca6](https://github.com/memetics19/anvil/commit/bb62ca6e675b2075cfe42e66920e3068b657fdd4))
* **security:** bump patched Caddy modules x/net, go-jose and chi (4 fixable CVEs) ([#83](https://github.com/memetics19/anvil/issues/83)) ([2fa0ffa](https://github.com/memetics19/anvil/commit/2fa0ffa2ae4c6612b56f015e41674a1e63dd268d))

## [0.9.0](https://github.com/memetics19/anvil/compare/v0.8.1...v0.9.0) (2026-10-28)


### Features

* **arr_stack:** the quality policy as code, 1080p and up ([#78](https://github.com/memetics19/anvil/issues/78)) ([cb63a90](https://github.com/memetics19/anvil/commit/cb63a908173789a32d6ac199a0e222b5494622da))
* **network_switch:** DHCP snooping, so only real DHCP servers answer ([#80](https://github.com/memetics19/anvil/issues/80)) ([3001f4c](https://github.com/memetics19/anvil/commit/3001f4c482cce5488c160ee9952391c34597b5e8))

## [0.8.1](https://github.com/memetics19/anvil/compare/v0.8.0...v0.8.1) (2026-10-27)


### Bug Fixes

* **provision:** two fixes from the first real install run ([#76](https://github.com/memetics19/anvil/issues/76)) ([93778b2](https://github.com/memetics19/anvil/commit/93778b2e269c58ddf8eac4a40f2a47327094f410))

## [0.8.0](https://github.com/memetics19/anvil/compare/v0.7.0...v0.8.0) (2026-10-27)


### Features

* anvil pools creates the ZFS data pools of a provisioned host ([#71](https://github.com/memetics19/anvil/issues/71)) ([c8ecd17](https://github.com/memetics19/anvil/commit/c8ecd1715f15400791645bcfd35b480de0c050aa))
* **provision:** power off the target and set Dell disks to Non-RAID ([#74](https://github.com/memetics19/anvil/issues/74)) ([6b16603](https://github.com/memetics19/anvil/commit/6b166031a40003e86dfb81b0bc84ec7712c5f252))

## [0.7.0](https://github.com/memetics19/anvil/compare/v0.6.4...v0.7.0) (2026-10-25)


### Features

* anvil rotate gives Radarr, Sonarr and Prowlarr new API keys ([#63](https://github.com/memetics19/anvil/issues/63)) ([57538cc](https://github.com/memetics19/anvil/commit/57538cc33c5dc7ff9abc769b3cf4d185df58b192))
* **cli:** anvil doctor --fix removes lab routes that hide the VPN ([#59](https://github.com/memetics19/anvil/issues/59)) ([879ec2b](https://github.com/memetics19/anvil/commit/879ec2bbac4c782518336967f1d89962a5a4531a))
* **cli:** anvil drift, the nightly check with a push to ntfy ([#64](https://github.com/memetics19/anvil/issues/64)) ([d5caab1](https://github.com/memetics19/anvil/commit/d5caab1373168e48f60a7700a874c037acf731d2))
* **pihole:** HaGeZi Multi PRO and deny regexes as code ([#54](https://github.com/memetics19/anvil/issues/54)) ([0f68b40](https://github.com/memetics19/anvil/commit/0f68b40fa74d97dba2745d5c8816a4f44dd77182))

## [0.6.4](https://github.com/memetics19/anvil/compare/v0.6.3...v0.6.4) (2026-10-24)


### Bug Fixes

* clearer increase-disk errors, each env.sh note once per run ([#52](https://github.com/memetics19/anvil/issues/52)) ([76a76df](https://github.com/memetics19/anvil/commit/76a76dfae2613db80053a028b9970c8f247a1dee))

## [0.6.3](https://github.com/memetics19/anvil/compare/v0.6.2...v0.6.3) (2026-10-24)


### Bug Fixes

* reach Vault, Radarr and Sonarr through the gateway when away from home ([#50](https://github.com/memetics19/anvil/issues/50)) ([0e1307b](https://github.com/memetics19/anvil/commit/0e1307bc1169044286ce851eba71c577c4c94534))

## [0.6.2](https://github.com/memetics19/anvil/compare/v0.6.1...v0.6.2) (2026-10-24)


### Bug Fixes

* **cli:** say why anvil media cannot load its settings, quiet git on fetch ([#48](https://github.com/memetics19/anvil/issues/48)) ([78d748d](https://github.com/memetics19/anvil/commit/78d748d7cdd6cdef992fd71a3e0861a37f195a45))

## [0.6.1](https://github.com/memetics19/anvil/compare/v0.6.0...v0.6.1) (2026-10-24)


### Bug Fixes

* **cli:** offer to fetch the repo when a command needs it and there is none ([#46](https://github.com/memetics19/anvil/issues/46)) ([1460905](https://github.com/memetics19/anvil/commit/14609053efbd280371e9d1c02dae1a9e34df59db))

## [0.6.0](https://github.com/memetics19/anvil/compare/v0.5.0...v0.6.0) (2026-10-24)


### Features

* **cli:** anvil media to search, download and follow movies and series ([#42](https://github.com/memetics19/anvil/issues/42)) ([e752f2d](https://github.com/memetics19/anvil/commit/e752f2d594fbd393e1301d8eee68662d94b3b29e))
* grow a VM's disk while it runs (anvil increase-disk, make grow-disk) ([#43](https://github.com/memetics19/anvil/issues/43)) ([8908be4](https://github.com/memetics19/anvil/commit/8908be4693ad9d3736528a413e302ab4dcaf2f31))
* **nfs_media:** the media library read-only over NFS to a Jellyfin in another home ([#44](https://github.com/memetics19/anvil/issues/44)) ([2a16207](https://github.com/memetics19/anvil/commit/2a162074072e0217966cbea5284175c63f78f43c))
* **pulse_agent:** host metrics from every lab VM to Pulse ([#40](https://github.com/memetics19/anvil/issues/40)) ([53bbfc4](https://github.com/memetics19/anvil/commit/53bbfc4067084cecc8fc96409f58f46adafb8214))

## [0.5.0](https://github.com/memetics19/anvil/compare/v0.4.2...v0.5.0) (2026-10-24)


### Features

* **docmost:** a wiki on frigate, reached at wiki.&lt;gateway domain&gt; ([#39](https://github.com/memetics19/anvil/issues/39)) ([96ada61](https://github.com/memetics19/anvil/commit/96ada614c4399be7033abc8860e3c828785097a0))


### Bug Fixes

* forget-host removes exactly one host's key, close guard test blind spots ([#37](https://github.com/memetics19/anvil/issues/37)) ([6063dd9](https://github.com/memetics19/anvil/commit/6063dd9f6540c5ee4ba7a741a52b81b822c05f3a)), closes [#34](https://github.com/memetics19/anvil/issues/34)
* **pulse:** hold after a failed restore, wait for a slow first install, read the right Vault mount ([#38](https://github.com/memetics19/anvil/issues/38)) ([0979c52](https://github.com/memetics19/anvil/commit/0979c52cb246e7a7ff5b33b54ee99ee67a887252)), closes [#33](https://github.com/memetics19/anvil/issues/33)
* **security:** drop IPv6 on segment interfaces before any other rule ([#35](https://github.com/memetics19/anvil/issues/35)) ([494d737](https://github.com/memetics19/anvil/commit/494d73743104ece891045f7e5323417f28a11b8f)), closes [#31](https://github.com/memetics19/anvil/issues/31)

## [0.4.2](https://github.com/memetics19/anvil/compare/v0.4.1...v0.4.2) (2026-10-23)


### Bug Fixes

* publish container ports on a named address, never all interfaces ([#24](https://github.com/memetics19/anvil/issues/24)) ([61cdf3c](https://github.com/memetics19/anvil/commit/61cdf3c51cdd76560a61f837463e9163c8d913e8)), closes [#19](https://github.com/memetics19/anvil/issues/19)
* **pulse:** a rollback restores the data instead of wiping it ([#23](https://github.com/memetics19/anvil/issues/23)) ([299cb82](https://github.com/memetics19/anvil/commit/299cb8284a690321965b6b4dca9e5ee8df66a0b9)), closes [#17](https://github.com/memetics19/anvil/issues/17)
* **pulse:** check the release image's signature before deploying it ([#29](https://github.com/memetics19/anvil/issues/29)) ([e0593e8](https://github.com/memetics19/anvil/commit/e0593e8dca9adfd5d822482d9a673fe841d230a5)), closes [#18](https://github.com/memetics19/anvil/issues/18)
* **pulse:** pass a generated setup token instead of the unused admin token ([#28](https://github.com/memetics19/anvil/issues/28)) ([fc488bf](https://github.com/memetics19/anvil/commit/fc488bfe7c767fe92f684c064a6c3b819c761400)), closes [#18](https://github.com/memetics19/anvil/issues/18)
* **pulse:** skip a failed release, prune backups after a failure, follow one major ([#30](https://github.com/memetics19/anvil/issues/30)) ([2f2175f](https://github.com/memetics19/anvil/commit/2f2175fb39cc5e643c407df97ae1a874b5ff8213))
* **security:** check SSH host keys before sending the become password ([#27](https://github.com/memetics19/anvil/issues/27)) ([d938a55](https://github.com/memetics19/anvil/commit/d938a55526fc3df7286510bad9a6efe91d4b87fd)), closes [#20](https://github.com/memetics19/anvil/issues/20)

## [0.4.1](https://github.com/memetics19/anvil/compare/v0.4.0...v0.4.1) (2026-10-23)


### Bug Fixes

* **pulse:** build the docs from the repository root ([bd1fb06](https://github.com/memetics19/anvil/commit/bd1fb06dcfcb564da5c2bcf0f9389b525dd6a6af))
* **pulse:** build the docs from the repository root ([ad91dde](https://github.com/memetics19/anvil/commit/ad91dde684003f20d662e987b6faf3caa3e32b64))
* **pulse:** pass PULSE_DB, the Pulse 3 name for the database path ([e69599e](https://github.com/memetics19/anvil/commit/e69599e2469b620533a8324181c00f99a11b23d9))

## [0.4.0](https://github.com/memetics19/anvil/compare/v0.3.0...v0.4.0) (2026-10-23)


### Features

* **apt_repo:** one apt repository for anvil and pulse ([c348357](https://github.com/memetics19/anvil/commit/c348357840baa3e1f9dc5e8fd160c007b89202db))
* **apt_repo:** one apt repository for anvil and pulse ([d89f9ee](https://github.com/memetics19/anvil/commit/d89f9ee9e7c14b2c1d244235acf22db102fa306d))
* **apt_repo:** one repository for several projects, pulse next to anvil ([84e042b](https://github.com/memetics19/anvil/commit/84e042b77041721dce3ca8abb81e2a61b3fa7273))
* **cloudflared:** one pinned version, rolled out one connector at a time ([82a7323](https://github.com/memetics19/anvil/commit/82a7323dee4b803eb672916f518f3d2c2d6f1026))
* **cloudflared:** pinned at 2026.10.3, rolled out one connector at a time ([6383650](https://github.com/memetics19/anvil/commit/6383650943da961c3e906cb637151f83a02d6ab1))


### Bug Fixes

* **caddy:** build with golang.org/x/net 0.61 and current base and builder digests ([5afe5a0](https://github.com/memetics19/anvil/commit/5afe5a0a62887ae454d5f697b82a00791ebdd3cb))
* **caddy:** other roles use the resolved image tag, not the template lookup ([5073f9e](https://github.com/memetics19/anvil/commit/5073f9e571f2bad6356f0ade5f359d4212445090))
* filestash on its rebuilt image, the IPTV helper on Debian trixie ([e7fc753](https://github.com/memetics19/anvil/commit/e7fc753a6bffab378e3270992c009ec25b3a358e))
* **iptv:** a failed guide grab warns when a guide already exists ([172e2fc](https://github.com/memetics19/anvil/commit/172e2fcd82ab96557c5eeba10e12fd46cb976025))
* patched Caddy on every host, rebuilt images, IPTV on trixie ([8c469e7](https://github.com/memetics19/anvil/commit/8c469e7bc169f832e7c56b7de3e23071655055fa))
* the Caddy containers on the netbird VM run the patched build ([fb4b776](https://github.com/memetics19/anvil/commit/fb4b7765815aed2b190e3d61ecdc8eaf282ce87f))
* **vaultwarden:** the Alpine build of 1.37.4 ([be26449](https://github.com/memetics19/anvil/commit/be26449db429adb374138848becfcf65834216a1))
* **vaultwarden:** the Alpine build of 1.37.4 (no CRITICAL or HIGH findings) ([8ad6d4d](https://github.com/memetics19/anvil/commit/8ad6d4de7352f72bb6902f0a77a906acdf49aa5e))

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
